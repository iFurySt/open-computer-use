# 架构总览

这个仓库当前已经从模板收敛成一个本地 `computer-use` 项目。主线仍是 Swift 实现的 macOS automation MCP server，同时新增了实验性的 Windows 和 Linux runtime，用独立 Go 二进制暴露同一组 9 个 native Computer Use tools；Codex plugin 再在 native MCP 之上增加持久 Node.js REPL，向模型暴露 `js` / `js_reset`。

## 当前目录结构

- `apps/OpenComputerUse`
  主入口，负责 `mcp`、`doctor`、`list-apps`、`snapshot`、`call`、`turn-ended` 等 CLI 命令，以及 `-h` / `--help` / `-v` / `--version` 这类全局参数；不带参数启动时会先检查权限，只有缺失时才进入无 Dock 图标的 app 模式权限引导窗口，`doctor` 也只会在检测到缺失权限时拉起这套 onboarding UI。
- `apps/OpenComputerUseFixture`
  本地 GUI fixture app，用来承载低风险、可预测的点击/输入/滚动/拖拽验证路径。
- `apps/OpenComputerUseSmokeSuite`
  端到端 smoke runner，会拉起 fixture 和 MCP server，并通过 JSON-RPC 真实调用 9 个 tools；同时也支持单独的 visual cursor idle smoke，用跨进程 observation file 断言等待下一次 move 时是 anchored tip + tiny rotate wobble，而不是横向漂移。
- `apps/OpenComputerUseWindows`
  实验性 Windows runtime。它不依赖 Swift 或 `.app` bundle，Go CLI/MCP 入口会嵌入 PowerShell UI Automation bridge，构建产物是 `open-computer-use.exe`，并随已有 npm 包的 `dist/windows/<arch>/` bundled artifacts 分发。
- `apps/OpenComputerUseLinux`
  实验性 Linux runtime。它不依赖 Swift 或 `.app` bundle，Go CLI/MCP 入口会嵌入 Python AT-SPI bridge，构建产物是 `open-computer-use`，并随已有 npm 包的 `dist/linux/<arch>/` bundled artifacts 分发。
- `packages/OpenComputerUseKit`
  核心库，包含：
  - MCP stdio transport 与 tool registry
  - app discovery
  - Accessibility / 窗口 snapshot
  - 键鼠输入模拟
  - software cursor overlay
  - fixture test bridge
- `experiments/CursorMotion`
  独立的 Swift cursor motion lab，用于试验 `Bezier + arc + spring` 参数模型、调参 UI 和独立渲染，不直接耦合主 MCP runtime。
- `experiments/StandaloneCursor`
  新的独立 Swift cursor viewer，直接复用 `scripts/cursor-motion-re/official_cursor_motion.py` 里收敛出来的候选路径、score 与 raw spring timeline，用来观察更贴近 binary lift 的表现。
- `scripts/`
  仓库级自动化命令，包括 smoke test、`.app` 打包入口、Windows `.exe` / Linux binary 构建入口、npm 分发脚本、GitHub Release direct-download archive 打包、`scripts/node-repl/` 的 JS REPL adapter 与 npm CLI controller，以及 `scripts/computer-use-cli/` 这个用于探测官方 bundled `computer-use` 的 Go helper。
- `skills/`
  面向 agent runtime 的可安装 skill。当前 `skills/open-computer-use/SKILL.md` 只作为轻量入口和目录，安装、MCP/CLI 使用、排障等细节拆到相邻 `references/` 文件里按需加载；`scripts/package-skill.sh` 负责校验并打包 `.zip` / `.skill` 制品。
- `docs/`
  逆向分析、执行计划、history 和项目约束。

## 运行分层

### 1. App Mode 层

- `OpenComputerUse` 默认 app 模式会拉起 `PermissionOnboardingApp`。
- app bundle 以 `LSUIElement` agent-style 形态运行，默认不在 Dock 暴露常驻图标，但仍可按需显示权限窗口。
- 当用户从终端执行 macOS 版 `open-computer-use mcp`、`doctor`、`call`、`snapshot` 或 `list-apps` 时，CLI 会先通过 LaunchServices 启动同一个 `.app` bundle 的隐藏 app agent，并通过用户临时目录下的 Unix domain socket 转发请求；真正调用 Accessibility、ScreenCaptureKit 和动作 tools 的进程始终是 `Open Computer Use.app`，不是 iTerm / Terminal / Node launcher。默认 Socket 文件名保持历史兼容；嵌入式宿主可设置 `OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE`，使其使用 namespace 摘要对应的私有 Socket，避免与其他 OCU bundle 共用 Agent。
- CLI 与 MCP proxy 会把调用进程中 `OPEN_COMPUTER_USE_*` 前缀的环境变量随请求转发给 app agent，并只在该请求执行期间临时覆盖 agent 环境；这让 `click_method=global` 的进程级安全门和 debug 开关在 app-agent 架构下仍按调用方配置生效。
- 主窗口负责渲染 `Accessibility` / `Screen & System Audio Recording` 两类权限卡片、`Allow` / `Done` 状态和 relaunch 后的状态收敛；当两项权限都已完成时会自动关闭，不再要求用户手动退出。
- 辅助 drag panel 会跳转到对应的 `System Settings` 页面；点击 `Allow` 后，panel 会从主窗口里的按钮位置做一段 spring + curved frame 的入场，再落到 `System Settings` 内容区下沿。panel 默认保持在窗口右侧内容区下方居中并固定贴近窗口底边，不再依赖实时扫描权限页内部 `+ / -` 控件行；窗口层级上会显式排在当前 `System Settings` 窗口之上，避免被权限列表内容盖住，同时尽量减少对系统设置自身滚动区域的干扰。panel 内也补了显式返回按钮，允许用户中断当前 guidance、回到 onboarding 主窗口重新选择权限步骤。
- 权限状态会合并 TCC 持久授权记录与当前 app 进程的 runtime preflight：TCC 中任一匹配 client 已授权即可视为 granted，避免 CLI 子进程与 GUI app 对授权状态看到不一致的结果；如果当前 `.app` 进程已经通过 `AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()`，也会立即视为 granted，避免 stale 或不匹配的 TCC path 记录让 onboarding 浮层继续停留。正式 release 仍以 CI 打出来的 `Open Computer Use.app` 为准，而本地 debug/dev 打包现在显式命名为 `Open Computer Use (Dev).app`，并在 dev bundle 运行时优先认当前 dev 副本，避免系统设置里出现两个完全同名的条目。

### 2. MCP 层

- 面向 MCP host 的外部 transport 仍是 `stdio`；macOS 终端 CLI 到 `.app` app agent 之间额外有一层本地 Unix domain socket 代理，用来保证真实 automation 运行在 app bundle 权限身份下。
- 当 `OPEN_COMPUTER_USE_VISUAL_CURSOR` 未被显式关闭时，`mcp` 命令会切到一个最小 AppKit runtime：主线程保留 event loop 承载 overlay UI，stdio server 仍在后台线程串行读取与响应。
- 请求 framing 采用一行一个 JSON-RPC message。
- 当前支持的 method：
  - `initialize`
  - `notifications/initialized`
  - `notifications/turn-ended`
  - `ping`
  - `tools/list`
  - `tools/call`
- `notifications/turn-ended` 是开源版显式的 turn boundary hook；收到后会清理当前进程里的 visual cursor overlay、occlusion keep-alive 和 agent display。CLI `open-computer-use turn-ended [payload]` 也会通过 macOS distributed notification 通知正在运行的 AppKit MCP / app-agent 进程执行同一类清理，用于接 Codex legacy notify 的 after-agent payload。stdio server 退出和 app-agent client connection 关闭也会执行该 session cleanup。

### 3. Tool Service 层

- `ComputerUseService` 负责把 Computer Use tool 请求映射到本地能力，`ComputerUseToolDispatcher` 则把 native tool 的参数解析与 service 方法分发收敛成 MCP server 和 `open-computer-use call` 共用的一层。
- Codex plugin 的 `.mcp.json` 默认不再把 native tools 直接暴露给模型，而是启动 `scripts/node-repl/open-computer-use-repl.mjs`。adapter 以 child MCP client 连接同一个 native runtime，并只对外列出 `js` / `js_reset`；JavaScript 通过异步 app-bound API（`cua.getApp(...)`、`app.click(...)`、`app.getAXState()` 等）调用 native tools。
- REPL 使用 Node.js 自带的 evaluator，因此保留 top-level `await` 和跨调用 lexical bindings；真正执行代码的 kernel 位于 Worker 中，超时会终止 Worker 并重建干净 session，避免 `while (true)` 挂死 MCP transport。
- npm launcher 还直接提供 `ocu js` 和 `ocu repl`：前者为一次性 Worker/native MCP session，后者在当前终端内保留同一个 session 和 binding；两者退出后都会关闭 Worker 与 native MCP child。`ocu capabilities [--json]` 在不启动 native MCP 的情况下报告 Node、adapter、kernel 和当前平台 native artifact 是否齐全。help 始终显示 code-first 命令并标记 availability，不按环境动态隐藏接口。
- npm bin 当前本身通过 `#!/usr/bin/env node` 启动，因此完全没有 Node 的 shell 无法进入 help/capability 检测；launcher 启动后会复用 `process.execPath`，不会再次从 PATH 解析 Node。若未来要求零 Node 前置，应把最外层入口替换成 native bootstrap 或随包分发 Node。
- 这是增量迁移：`open-computer-use mcp` 仍是原生 9-tool compatibility surface，已有 CLI、其他 MCP host 和 smoke 不需要切换。
- `list_apps` 通过 Spotlight metadata query 拉取标准 application 目录里的 app bundle，并读取 `kMDItemUseCount` / `kMDItemLastUsedDate_Ranking` 这类系统元数据；再与 `NSWorkspace` 的运行态 app 合并，输出“当前运行中 + 近 14 天用过”的视图。
- `get_app_state` 优先走真实 AX / 窗口截图；真实 app 必须同时有未最小化的 `AXWindow` 和可匹配的 on-screen `CGWindow`。如果目标 app 只是隐藏或暂时没有 on-screen window，会先 best-effort unhide / activate / `open -b` / `AXRaise` 并短暂重试，以贴近官方 `computer-use` 会把 Lark / Electron 窗口拉回再采集的行为；恢复后仍无法匹配时返回官方风格的 `Apple event error -10005: cgWindowNotFound`，不再把 application 根节点或无截图窗口伪装成可操作状态。当目标是仓库内 fixture app 时，回退到 fixture 导出的合成状态。真实 AX tree 默认在 macOS、Linux、Windows 上最多渲染 1200 个节点、64 层深度；显式 `get_app_state` / `snapshot` 可通过 `max_tree_nodes` / `max_tree_depth` 覆盖预算，action tools 的刷新结果仍使用默认预算。snapshot 文本默认截断到 500 字符；显式 `get_app_state` / `snapshot` 可通过 `text_limit` 正整数或 `"max"` 覆盖，action tools 的刷新结果仍使用 500 字符默认值。对 Electron/WebView 这类深层 UI 会压缩空 `AXGroup` / `AXUnknown` wrapper、过滤 `AXScrollToVisible` 噪音和空字符串属性，避免 action-critical 的输入框被无语义容器挤出节点预算；但通用节点中的 `AXPress` / `AXConfirm` / `AXOpen` 子节点会形成文本摘要边界，避免多个可点击选项被合并成一个 container。这类动作节点如果 frame 有效、尺寸紧凑且不包含带 URL 的 `AXLink` 后代，会保留为带窗口相对 `Frame` 的 `button`，并用短文本后代作为按钮摘要，让 icon-only 和文字 Web 控件都能获得可区分的 `element_index`；包含带 URL 的 `AXLink` 后代时保留通用 wrapper 和链接子节点，避免导航链接被摘要吞掉。对原生 open panel / Finder column view 这类把内容放在 `AXContents` / `AXVisibleChildren` 里的控件，也会把可见文件项纳入元素树。
- MCP 的 9 个核心 tools 的 description / input schema 按官方 `computer-use` 文案和参数面收敛，macOS 额外提供 `query`，尽量减少 host 侧提示词和 tool surface 偏差。
- JS REPL 的 API 和当前官方 code-first 形态对齐到异步 app binding，而不是把离散 tools 简单包成同步函数。snapshot 的 `windowPlacement` 以及 keyboard action 的 `keyMethod` 会转换成 native tool 的 snake_case 参数。实现不复制或运行 proprietary `@oai/*` package；协议和行为记录在 `docs/references/js-repl.md`。
- `open-computer-use call <tool> --args '{...}'` 会直接输出 MCP-style JSON result；`open-computer-use call --calls '[...]'` / `--calls-file <path>` 会在同一进程里顺序执行 JSON 数组里的 tool calls，并复用同一个 `ComputerUseService` 内存态，因此 `get_app_state` 之后的 action tool 可以继续使用同一轮 snapshot 的 `element_index`。序列执行默认会在成功的相邻操作之间 sleep 1 秒，也可以用 `--sleep <seconds>` 覆盖；遇到 `isError=true` 的 tool result 后停止。
- 对真实 app 的 `get_app_state` / action tool 入口，当前只保留一层密码管理器 bundle denylist：bundle-id 直传时直接返回 safety denial；名称匹配时默认不解析到这些 app。终端、Chrome / Atlas 和系统组件不再属于内置阻止目标。
- 普通 app 的 element frame 当前按“窗口左上角为原点”的 window-relative 坐标输出，便于后续把 `element_index` 和截图坐标统一到同一套参考系。
- 三个平台的显式 `get_app_state` 均支持 `include_ax` / `include_screenshot`，默认 true，至少保留一项。JS 对应 `includeAX` / `includeScreenshot`，CLI snapshot 提供同名连字符参数。关闭 AX 跳过树、焦点和选区，并使旧快照 / 查询索引及别名失效；关闭截图跳过捕获与编码，元素操作仍可用，截图坐标操作须重新获取图片。参数经 macOS app agent 转发；不改变动作回读，也不做自动图片去重。见 [按需观察](selective-observation.md)。
- macOS 额外提供 `query`、`select_text` 和 `set_position`，当前 native surface 为 12 个工具；Linux / Windows 仍为 9 个核心工具。JS `app.selectText(elementIndex, text, {prefix?, suffix?, selection?})` 复用快照或 query 索引，支持选中文字及前后光标。按字面文本和 UTF-16 定位、拒绝歧义；写入前及返回前检查会话，验证文本未变且实际选区等于请求，即使关闭完整回读也不能省略验证。失败通过 native `isError` / JS 异常传出；结果刷新使用 read-only recovery，不通过激活、键盘或真实指针补救。
- `click` / `set_value` 在执行真实动作前后，会额外驱动一层透明 `SoftwareCursorOverlay` window：两者的移动阶段现在共用一条 heading-driven 的官方风格 motion 内核，显式把“当前 cursor 朝向”和“最终 resting pose”一起喂给选路器，优先生成需要时先掉头、再沿车头方向推进的 C 形/单侧大弧轨迹；首次显示时按官方 binary 的 fresh state 从 AppKit 全局 `(0,0)` window origin 生成起点，后续动作继续复用上一帧 visible tip。真正显示出来的 cursor 不再直接等于 path sample，而是经过一层独立的 visual dynamics 状态，把 visible tip、velocity、angle 和 fog/offset 持续推进。`click` 结尾会衔接 click pulse 和更明显但仍然很小的 rotate wobble，`set_value` 则只做 settle / idle，不给 pulse；两者收尾后会在目标点继续保持 idle 状态，等待下一次动作时 tip 保持 anchored、只保留可感知的小角度摆动；只有连续 30 秒没有新动作时才做 cleanup，这样连续 tool call 不会反复从 fresh `(0,0)` 起步；如果宿主在任务 / turn 结束时发出 `turn-ended`，cursor 会立即消失并清掉本轮位置状态。
- overlay 用目标点相对窗口的锚点跟随窗口移动；行进、settle、点击反馈和 idle 都读取最新缓存帧，发现位置变化时直接重定位可见 tip 并清掉旧速度。窗口帧在后台串行读取，最多 30 Hz、同时最多一个请求，避免 AX 阻塞渲染线程；优先读取快照持有的 AX 窗口，仅在没有 AX 元素时使用窗口列表，读取失败保留最后有效帧。只保留当前窗口的追踪状态，reset / idle 超时后释放；这层跟随只调整显示位置，输入投递仍走既有路径。
- overlay 的 visual style 不再自己从官方 app bundle 裁 `SoftwareCursor` 小图；主 MCP runtime 现在和 `CursorMotion` 一样优先渲染仓库里沉淀的 `official-software-cursor-window-252.png` baseline，只有资源缺失时才退回 `OpenComputerUseKit` 内部的程序化 pointer/fog fallback。命中点 anchor 仍固定在 `126x126` 画布里的同一组 tip-offset 上；glyph 自身的 neutral heading 继续沿用 `CursorMotion` / 官方 baseline 的 `-3π/4`。主 runtime overlay window 按 AppKit 全局坐标移动，因此在把 AX / `CGWindowList` 产出的 y-down screen-space 点击目标喂给 overlay 之前，会先转换成对应屏幕的 AppKit 全局坐标；路径选路用屏幕上实际可见的 AppKit forward heading，进入 visual dynamics / render state 前则把 velocity 的 y 轴翻回 CursorMotion 的 y-down screen state，再交给 AppKit 绘制层做角度和 `dy` 翻转。程序化 fallback 保留 neutral artwork correction，把它的天然轮廓轴对齐到 `CursorMotion` / 官方 baseline 的 `-3π/4` forward 方向，但不让实验线依赖 runtime 代码。
- overlay 的层级不再固定 `.floating`；现在会跟随 snapshot 命中的目标 window id / layer，把自己排到该目标 window 之上，而不是粗暴压到所有前台 app 最上层。
- overlay 的曲线路径不再只按固定 Bezier 模板生成；当前主线采用 reverse-engineering 约束下的 heading-driven candidate 族，候选只保留 `direct` / `turn` / `brake` / `orbit` 这些能稳定产出单侧主弧的 family，并继续保留 target-window 命中策略作为同类候选间的 tie-break。原始 binary lift 恢复出来的 `20` 条路径和 score 仍然保留在独立的 `StandaloneCursor` viewer / Python 重建脚本里，用于对照分析，不再直接作为 runtime 默认 chooser。
- overlay 的 progress 曲线也不再是固定 `easeInOut`；主线现在复用官方 `response=1.4`、`dampingFraction=0.9`、`dt=1/240` 的 spring/`VelocityVerlet` 形状，默认 move 时长对齐已恢复出的 close-enough endpoint-lock 时间 `343 / 240 = 1.4291667s`，不再按路径距离额外压缩。
- overlay 不再依赖临时 `terminal settle` 补丁来修尾；主线现在统一改成“路径层给目标点，visual dynamics 层给可见姿态”的双层模型，所以 move 末段、pulse 和 idle 共用同一套状态，不会再出现 endpoint 锁住后只剩原地翻角的收尾。
- overlay 的渲染输入也从单一 `rotation` 扩展成 `rotation + cursorBodyOffset + fogOffset + fogScale`，让速度滞后能真正体现在画面上，而不是只存在于主循环内部状态；其中 `rotation` 现在按二进制里 `SoftwareCursorStyle.angle + CursorView._animatedAngleOffsetDegrees` 的分层去近似，不再把“跟随运动方向的主朝向”和“小幅 wiggle offset”压成同一个受限小角度。
- 动作型 tools 对普通 app 采用“非侵入优先，物理指针路径显式 opt-in”策略：
  - `perform_secondary_action` 只执行目标元素已经暴露出来的 AX action；Safari 这类 AppKit custom action descriptor（例如 `Name:close tab ...`）会显示为短名称并准确映射回过滤后的原始 AX action，避免 raw/rendered action 错配；短名称与其他显示名称或任一其他原始 AX action（包括被过滤的动作，忽略大小写）冲突时保留完整 descriptor，保证输出 selector 不被原始动作精确匹配抢占；无效或歧义 action 返回官方风格的 `... is not a valid secondary action for ...`，fixture 的 `Raise` 路径也不再为了测试去准备全局物理指针输入
  - `set_value` 会先用 `AXUIElementIsAttributeSettable(kAXValueAttribute)` 判断目标是否真的是可设置值元素，只有 settable 时才调用 `AXUIElementSetAttributeValue`；不可设置时返回官方风格的 non-settable 错误，不退到键盘输入、剪贴板或未公开的文本替换接口
  - macOS `set_position` 只写 `AXPosition` / `AXSize`（先检查可设置，先写尺寸再写位置），坐标与 `click` / `drag` 一样是截图像素。每次写入后回读：仅当元素仍在原处时报错；应用夹紧或吸附时成功并注明实际落点；无法回读时注明未验证。不发送指针或鼠标事件，是默认 `drag` 无法移动窗口（#53）时的后台替代
  - `click.click_method` 是开源版的可选扩展，支持 `auto`（默认）、`accessibility`、`app_post`、`sky_click` 和 `global`。未传参数时继续使用原有自动路由；显式模式不会静默 fallback 到其他实现。`accessibility` 只接受 `element_index`；其余 mouse 路径可以使用 `element_index` 的计算落点或原始 `x/y` 坐标。
  - element-targeted `click` 的 `auto` 左键路径会先试原生列表的 `AXSelectedChildren` 选择，再试 `AXPress` / `AXConfirm` / `AXOpen` 这类真正语义化的激活动作；如果目标本身不可点，还会继续尝试其子孙 AX 元素（例如 Finder sidebar row 下面暴露 `AXOpen` 的 cell）和命中点附近的 AX hit-test 结果；这些都没处理时，表格 / 大纲里没有 press 动作的行（或行内 cell）会通过可设置的 `AXSelected` 选中（`click_method=accessibility` 同样适用），最后进入现有 non-AX 分支：未开启全局指针环境变量时使用 `postToPid` 定向鼠标事件，开启时直接使用全局 HID 事件。`AXRaise` / `kAXMainAttribute` / `kAXFocusedAttribute` 这类 activation-only fallback 只允许窗口级元素使用，避免普通静态文本或容器把“获得焦点”误报成“点击已处理”；`click_count > 1` 也会优先重复可用的 AX action。
  - 显式 `click_method=accessibility` 只执行上述 AX 语义动作；显式 `click_method=app_post` 绕过 AX 候选和后代扫描，直接通过 `CGEvent.postToPid` 向目标进程发送 `mouseMoved` / down / up；显式 `click_method=sky_click` 只在 macOS 接受左键单击/双击，它验证当前 snapshot 的 `CGWindowID` 仍为同一 PID 所有且 on-screen，仅通过 `SLPSPostEventRecordTo` 让目标应用短暂进入 synthetic-active 状态，绝不向真实前台应用发送 defocus record，再按 Chromium-compatible recipe 发送 target move、`(-1,-1)` primer 和真实 down/up。每个鼠标事件同时经动态解析的 `SLEventPostToPid` 与公开 `postToPid` 投递，并带 window-local location、PID/window 和 click-group 字段；renderer settle 后只撤销目标的 synthetic-active 状态。`sky_click` 的 action-result snapshot 刷新也禁止 activate / `AXRaise` 恢复，目标状态瞬时不可读时直接失败。它不改变 `auto`，任一步失败也不 fallback。显式 `click_method=global` 同样绕过 AX，但通过 `.cghidEventTap` 发送系统级指针事件。`global` 还必须设置 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`，否则在移动 visual cursor 或发送输入前拒绝请求。
  - `get_app_state` 解析目标窗口时先看 on-screen 窗口，再退到所有窗口，所以位于其他 Space 的窗口不会触发 activate / raise 恢复；拍到未被遮挡的窗口后会关闭它的 WindowServer occlusion 通知（`WindowOcclusionKeepAlive`），之后被遮挡或切换 Space 时 Chromium / Electron / WebKit 仍保留页面与 `AXWebArea`。keep-alive 保存 SPI 返回的原始开关状态，并在 turn-ended、MCP/app-agent connection 关闭、server 正常关闭或进程退出时恢复；恢复失败的记录保留到后续重试。因为 snapshot 会维护该状态，macOS `get_app_state` 不声明 `readOnlyHint`。Chromium 系 app 的 web AX tree 是懒加载的，窗口可见时最多重走 3 秒，被遮挡时在 tree 末尾追加说明。`sky_click` 不再要求窗口 on-screen。详见 `docs/references/macos-window-visibility-and-spaces.md`。
  - 窗口截图主路径是 WindowServer 的 `SLSHWCaptureWindowList`（任何 Space、被遮挡均可，15–45 ms），ScreenCaptureKit 为 fallback；AX root window 通过 `_AXUIElementGetWindow` 直接绑定 `CGWindowID`。输入 recipe 的固定间隔都是环境变量可调的校准旋钮，默认值来自基准测试（见 `docs/references/macos-window-visibility-and-spaces.md`）。
  - `get_app_state.window_placement` 是开源版的可选扩展：`keep`（默认）、`agent_display`、`restore`。`agent_display` 通过 `AgentDisplay` + `packages/OpenComputerUseVirtualDisplayShim` 创建 agent 专用 virtual display，用 AX 位置把目标窗口的 frame 移过去（不激活、不抬升），让已被遮挡或在其他 Space 的窗口对其 app 真正可见；`restore` 按 app PID 恢复当前 runtime 停放的全部窗口，session cleanup 或进程退出也会恢复全部窗口并销毁显示器。恢复失败时保留原位置记录和 virtual display，避免把未恢复窗口误记为成功并允许后续重试；已关闭的窗口则直接清除记录。shim 捕获私有 KVC/selector 的 Objective-C exception，并把不兼容系统收敛为创建失败。Windows / Linux 对非 `keep` 值返回 unsupported。
  - `type_text.key_method` / `press_key.key_method` 是开源版的可选扩展，支持 `auto`（默认）和 macOS-only 的 `sky_key`。`sky_key` 复用 `sky_click` 的 target-only synthetic-active record，再投递 yabai 的 make-key-window record 让目标 app 在进程内把当前 snapshot 窗口设为 key window，之后走现有 `CGEvent.postToPid` 键盘路径；带 `cmd` 的单字符组合键改为在目标 AX 菜单栏找到对应菜单项并 `AXPress`。它不要求窗口 on-screen（可用于其他 Space），但对隐藏 app fail closed；action-result snapshot 与 `sky_click` 一样使用 read-only recovery policy。
  - 对 renderer 合成的 summary `text` 行，`click` 不再默认点击父容器中心；这类元素使用左侧安全锚点。对普通 row/container/text 的后代候选，也会过滤右侧紧凑 hover action（例如 Lark / Electron 会话列表里的“完成”勾），避免把主行点击误操作成 side action；Electron/Lark 这类 app 的 WebArea 合成文本会优先寻找紧邻的行级 `AXPress` 祖先并静默执行，避免用物理鼠标点行。浏览器 WebArea（例如 Chrome/GitHub）不走这条 Electron-scoped 行级祖先点击优化，仍保留通用 link/container 点击路径。命中点如果只反查到覆盖整页的 Electron/WebArea 级 AX 元素，不再继续扫描整个大容器的子孙候选，避免一次行点击被远处的可点击元素截走。
  - `AXUIElementCopyElementAtPosition` 做坐标命中，尽量把 coordinate click 反解成可操作 AX 元素
  - `CGEvent.postToPid` 定向发送键盘事件，避免为了 `type_text` / `press_key` 抢前台；`type_text` 会把文本按 Unicode extended grapheme cluster 聚合成小批量 `keyboardSetUnicodeString` 事件，避免中文标点、emoji / 代理对和组合字符被逐个 UTF-16 code unit 拆开后在 Electron 富文本输入框里乱序或变形。如果当前 focused element 的 `AXValue` 可设置，`type_text` 会优先按可编辑内容追加并写回 `AXValue`，这覆盖 Feishu / Electron 富文本输入框不可靠接收后台键盘事件的场景，并会过滤已知占位提示，避免把 placeholder 拼进草稿；如果当前 focused element 不是可编辑文本目标，`type_text` 会报错要求先 click 文本输入区或使用 `set_value`，不再把无效果的后台键盘投递当成成功；`press_key` 的 xdotool parser 覆盖官方 binary key table 里常见的 `BackSpace`、`Page_Up`、`Prior` / `Next`、`F1...F12` 和 `KP_*` alias
  - `scroll.pages` 对齐官方 `1.0.755` 的 `number` schema，支持小数页数；整数页且目标暴露 `AXScroll*ByPage` 时优先走 AX action，否则用 `CGEvent.postToPid` 向目标进程定向发送 scroll event
  - `drag` 仍是 coordinate-only API，但默认不再使用全局 `.cghidEventTap` mouse event；默认改为 `CGEvent.postToPid` 定向发送 mouse move / down / dragged / up 事件，避免移动用户真实硬件光标；这些 coordinate tool 的 `x/y` 先按 screenshot pixel 坐标解释，再依据截图像素尺寸与目标 window bounds 的比例映射回 window point / Quartz global 坐标，避免 Retina 窗口上把 2x 像素误当成 1x point 导致点击落到错误位置
  - `click` / `scroll` / `drag` 在环境变量未开启的默认配置下不会走全局 `.cghidEventTap`，因此不会移动或抢占用户真实鼠标；`OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 是全局指针能力的进程级安全门，显式 `click_method=global` 仍必须通过这层授权。默认路径不再为了 fallback 调用 `NSRunningApplication.activate`。`drag` 的结果会在 snapshot 文本之后、截图之前附带一条 `Drag delivered via ...` 文本项，说明本次走的是 `app_post` 定向投递还是全局指针路径；默认路径下同时说明 `postToPid` 事件不经过 window server，因此无法驱动窗口移动、文本拖选、Finder 拖放这类 window server 拖拽会话。`drag` 的 tool description 也同步说明了这一限制和对应环境变量。显式开启全局路径后，拖拽使用默认 event source 向 HID tap 投递，按距离插值并为每步写入位移 delta；macOS 26+ 的 down / dragged / up 还会共享一个手势事件编号，使 window server 能识别窗口移动、文本拖选和 Finder 拖放所需的真实拖拽会话

### 4. Fixture Bridge

- `OpenComputerUseFixture` 会把自己的窗口与元素状态写到临时 JSON 文件。
- 对 fixture 的 `get_app_state` 和少量测试专用动作，会通过 `FixtureBridge` 走显式 command 通道。
- 这个 bridge 只服务于仓库内 deterministic smoke path，不是面向真实第三方 app 的能力边界。
- 因为 SwiftPM 裸 executable 形式启动的 fixture 没有稳定的 bundle identifier，`list_apps` 会仅对 `OpenComputerUseFixture` 注入一个内部 synthetic identifier，保证 smoke suite 仍能覆盖 `list_apps`，普通第三方 app 仍按真实 bundle id 输出。

### 5. Cursor Lab

- `StandaloneCursor` 是一个新的独立 SwiftUI/AppKit demo target，可通过 `swift run StandaloneCursor` 本地启动。
- 这条线优先验证 Python 重建脚本已经收敛出来的核心：`20` 条候选路径、`measure + score`、`prefer in-bounds then lowest-score` 选路，以及 `response=1.4` / `dampingFraction=0.9` / `dt=1/240` 的 raw spring timeline。
- 当前它刻意不引入 speculative 的 wall-clock duration 映射，也不复用 `CursorMotion` 里更偏视觉手感试验的 pose dynamics。
- `CursorMotion` 是一个单独的 SwiftUI demo target，可通过 `swift run CursorMotion` 本地启动。
- 这条线优先验证 motion model 本身：当前主线是 heading-driven 的 turn / brake / orbit / direct candidate 族、spring progress、独立 visual dynamics 和 debug UI；moving 阶段真正画出来的箭头角度会持续跟随 visual dynamics 的主 heading，接近停住后再平滑回到默认 resting pose，并在 idle 阶段保留原地小摆角。
- lab 的 cursor 视觉继续以 `scripts/render-synthesized-software-cursor.swift` 为参考：优先使用仓库里保存的官方 `252x252` runtime baseline 图，缺失时再退回脚本里的 procedural pointer/fog 近似；settle 态也改成中心固定的小幅摆角，而不是继续沿 XY 轻微漂移。
- 当前它不接真实 tool call，也不回写主 `SoftwareCursorOverlay`，目的是把实验噪音与产品行为边界隔离开。

### 6. Windows Runtime

- Windows runtime 位于 `apps/OpenComputerUseWindows`，以 Go 维护 CLI、`call --calls` sequence、MCP JSON-RPC、tool schema 和进程内 snapshot cache。
- 构建入口是 `scripts/build-open-computer-use-windows.sh --arch arm64|amd64`，默认输出到 `dist/windows/<arch>/open-computer-use.exe`；npm release package 会把两个 Windows artifact 内置到已有 root/alias packages，Node launcher 按 `process.platform/process.arch` 自动选择。
- Go runtime 通过 `go:embed` 带上 `runtime.ps1`，执行 tool call 时临时落盘并调用 Windows PowerShell。PowerShell bridge 使用 `System.Windows.Automation` 做 app/window/element discovery、tree rendering、UIA pattern action、ValuePattern set value 和 ScrollPattern scroll；当目标 app 不暴露对应 pattern 时，fallback 到 `PostMessage` / `SendMessage` 形式的 Win32 window message。PowerShell 进程启动时会通过 `SetProcessDpiAwarenessContext` / `SetThreadDpiAwarenessContext` 对齐到物理坐标空间，因为操作文件里的 `windowBounds` 和 UIA frame 都是物理像素，而 DPI-unaware 进程的 `GetSystemMetrics` / `GetWindowRect` 返回的是虚拟化尺度。
- Windows runtime 默认只连接已经运行的 app，不会在 `get_app_state` 找不到进程时自动 `Start-Process`，也不会默认允许 `SetFocus` secondary action；这两条前台抢占路径分别需要 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1` 和 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1` 显式打开。`type_text` 默认优先对可写文本控件的 child HWND 发送 `EM_SETSEL` / `EM_REPLACESEL`，不再默认走可能触发前台激活的 UIA `ValuePattern.SetValue` fallback；需要旧行为时必须设置 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1`。UIA pattern 和 Win32 message fallback 本身仍是 best-effort：很多控件可以在后台响应，但 Windows 没有一套对所有 GUI toolkit 都等价于 macOS AX 的后台键鼠输入模型。
- Windows screenshot 会先检查主窗口可见、未最小化、未被 DWM cloaked、与 virtual screen 相交，并要求窗口宽高至少 64 像素且面积至少 20,000 像素；`list_apps` 也只列出通过这组可捕获性检查的窗口。PowerShell bridge 通过后，Go 层还会解码 PNG header 并用同一尺寸门槛复核。任一检查失败时 snapshot 仍可返回 UI Automation tree，但省略 MCP `image` block；coordinate click / drag 会明确失败，element-targeted action 仍可尝试。实现不会为退化窗口放大、补边或生成占位截图。窗口与 virtual screen 的交集判断在物理坐标下进行，因此在 125% / 150% 缩放且窗口完全位于虚拟化屏幕之外时不会误判为不可捕获。
- 这 9 个 tool 的协议面与 macOS 主线保持一致：`list_apps`、`get_app_state`、`click`、`perform_secondary_action`、`scroll`、`drag`、`type_text`、`press_key`、`set_value`。其中 element-targeted action 会优先复用上一轮 `get_app_state` 的 runtime id / automation metadata，coordinate action 使用 screenshot/window-relative 坐标。
- Windows `click_method=accessibility` 使用 UIA，`app_post` 始终使用 HWND 消息。`click_method=global` 要求 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`；开启后，auto 点击及 scroll 的 UIA 失败回退、drag 也可使用真实指针。`press_key` 的 auto 始终使用窗口消息，真实按键需显式 `key_method=global` 及同一环境开关。物理输入通过 SendInput 检查返回值、finally 释放按键 / 鼠标，核对观察的 PID / HWND、最新几何、前台及坐标命中窗口；普通 SetForegroundWindow 失败就拒绝，不模拟 Alt 强行抢前台。macOS-only sky_click / sky_key 继续明确拒绝。见 [Windows 输入说明](windows-input.md)。
- Windows UI Automation 需要运行在已登录用户的桌面 session 里。通过 SSH 作为脱离桌面的后台进程运行时，PowerShell 可以启动并返回 JSON，但系统可能不给它暴露顶层窗口；这种情况下 `list_apps` 会是空，`get_app_state` 可能返回 `appNotFound(...)`。
- Windows 已有独立 WPF 观察 fixture 和 Windows PR smoke，覆盖观察、滚动、物理输入及截图边界。其余工具 / toolkit 覆盖，以及 visual cursor overlay、installer/onboarding、code signing 仍待补齐。后续 TODO 记录在 `docs/exec-plans/active/20260422-windows-computer-use-runtime.md`。

### 7. Linux Runtime

- Linux runtime 位于 `apps/OpenComputerUseLinux`，以 Go 维护 CLI、`call --calls` sequence、MCP JSON-RPC、tool schema 和进程内 snapshot cache。
- Linux 支持与 macOS 一致的 `OPEN_COMPUTER_USE_ACTION_READ_BACK`：默认保持动作后等待并返回完整快照；设置为 `0`、`false`、`no` 或 `off`（忽略大小写与首尾空白）时，成功动作只返回 `ok`，跳过回读等待、AX、焦点/选区和截图采集，也不覆盖最后一次显式观察的索引缓存。REPL adapter 已自动设置此开关；调用方应在需要观察时显式调用 `get_app_state` / `getAXState()`，并在界面变化后刷新索引。`ok` 仅表示动作调用完成，不代表界面已完成更新或任务成功。显式观察不受开关影响，仍返回完整快照。
- 构建入口是 `scripts/build-open-computer-use-linux.sh --arch arm64|amd64`，默认输出到 `dist/linux/<arch>/open-computer-use`；npm release package 会把两个 Linux artifact 内置到已有 root/alias packages，Node launcher 按 `process.platform/process.arch` 自动选择。
- Go runtime 通过 `go:embed` 带上 `runtime.py`，执行 tool call 时临时落盘并调用 `python3`。Python bridge 使用 GNOME/GObject Introspection 暴露的 AT-SPI2 接口做 app/window discovery、accessibility tree rendering、semantic action、editable text、value set，以及 best-effort 的 key/mouse fallback；文本能力通过 `Accessible.get_interfaces()` 检测 `Text` / `EditableText`，不依赖不同 PyGObject 版本未必存在的便捷属性。
- Linux 上最接近 macOS AX 的是 AT-SPI2/D-Bus accessibility，而不是一套统一的后台键鼠输入模型。第一版优先使用元素暴露的 AT-SPI action、EditableText 和 Value 接口；coordinate `click` / `drag` 与 `press_key` 使用 AT-SPI event synthesis fallback，在 Wayland 下只能按 best-effort 处理。`press_key` 的具名键以 keysym 配合 `KeySynthType.SYM` 发送，修饰键以 X modifier mask 配合 `LOCKMODIFIERS` / `UNLOCKMODIFIERS` 保持；`PRESS` / `RELEASE` / `PRESSRELEASE` 只接受硬件 keycode，不能传 keysym。
- Linux runtime 需要运行在已登录桌面用户 session 里。缺少 `XDG_RUNTIME_DIR`、`DBUS_SESSION_BUS_ADDRESS` 或 display 环境时，Go runtime 会在启动 Python AT-SPI bridge 前尝试从 `/run/user/<uid>` 和常见桌面进程自动发现当前用户的 session bus、display / Wayland 值；纯 SSH tty 如果找不到已登录桌面 session，可以启动二进制，但不能直接 inspect 或操作 GUI session。
- `get_app_state` 的 accessibility tree 在 GTK/GNOME app 上可能很深，Linux bridge 使用与 macOS / Windows 一致的 1200 节点、64 层默认 tree budget，并支持显式提高 `max_tree_nodes` / `max_tree_depth`。截图通过 GDK root window best-effort capture；GNOME Wayland 可能返回黑图，bridge 会检测全黑采样并省略 image block。
- 焦点摘要和选区在快照已经选定的窗口里共用一次查找，分别受 `max_tree_nodes` / `max_tree_depth` 约束；到深度边界后不再读取下一层子节点，查找未完成时追加明确提示。选中文字使用标准 AT-SPI `get_n_selections` / `get_selection` 接口读取。实现与隔离 GTK 验证见 [Linux 焦点查找](linux-bounded-focus.md)。
- `OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN=1` 可省略明确非 SHOWING 节点的位置、值等详情，保留节点、索引及子树；默认关闭，未知状态继续完整读取。使用方式与真实 GTK 验证见 [Linux 隐藏控件详情](linux-hidden-details.md)。
- 这 9 个 tool 的协议面与 macOS / Windows 保持一致：`list_apps`、`get_app_state`、`click`、`perform_secondary_action`、`scroll`、`drag`、`type_text`、`press_key`、`set_value`。其中 element-targeted action 会优先复用上一轮 `get_app_state` 的 runtime path metadata，coordinate action 使用 screenshot/window-relative 坐标。
- Linux `click_method=accessibility` 映射到 AT-SPI action，`global` 映射到 AT-SPI mouse synthesis 并要求全局指针环境变量；AT-SPI 没有等价的进程定向 mouse dispatch，因此 `app_post` 和 macOS-only 的 `sky_click` 会在 snapshot lookup 前明确返回 unsupported，`key_method=sky_key` 也一样。`auto` 仍保持 AT-SPI action 优先、mouse synthesis fallback 的现有行为。
- Linux 动作回读已有独立 GTK fixture，可在私有 D-Bus / Xvfb 中通过 native MCP 复测；运行方式见 [Linux 动作回读](linux-action-read-back.md)。当前 Linux 侧仍是功能性第一版：没有 visual cursor overlay、没有 installer/desktop entry，也没有覆盖全部工具的 Linux fixture。后续 TODO 记录在 `docs/exec-plans/active/20260422-linux-computer-use-runtime.md`。

## macOS Locked Use 实验

- `locked-use status [--json]` 和 `doctor` 增加只读 session / Input Monitoring / 插件诊断，由 app agent 提供真实 runtime 权限状态。 `doctor --json` 保持纯权限 JSON，不弹权限引导；定向 AX `query` 在读取前和返回结果前检查会话与当前租约。
- 真实窗口 snapshot、缓存复用与事件投递检查当前控制台 session；锁屏或未知 / 切换用户状态明确拒绝。fixture 不属于真实桌面，继续支持 headless 测试。
- `LockedUseStateMachine` 是由独立 Broker 串行驱动的纯保护策略，覆盖一次性许可、租约、guardian heartbeat、接管和重锁确认；已接入管理员显式启用的 unlock 事务，受保护 legacy 闭环已实测，完整生产证据仍待完成。
- `experiments/LockedUse` 与独立脚本提供 deny-only Authorization 插件 ABI / 系统加载探针（仅独立 right），完整管理员验证组件另在 screensaver 授权链登记自定义分支并保留系统认证 fallback。独立 `OCUGuardian` 测试 app 先用共享的 `DisplayShieldSurface` 做不锁屏 / 不操作的 15 秒品牌遮罩 preview（倒计时仅记录到日志），再用 child watchdog rehearsal 验证输入接管、重锁、遮挡窗口 AX / ScreenCaptureKit 及只读 loginwindow 结构。新增签名 Broker、remote 机制、锁屏 Guardian 和安装入口仍处于验证阶段，普通 enable 安装服务并申请权限，服务启动仍严格验证同团队组件签名。
- `LockedUseNative` 读取 Unix socket 的内核 audit token；`LockedUsePeerIdentity` 验证动态进程签名；`LockedUseClientApprovals` 从 root 所有、不可由普通用户写入的目录加载批准记录；`LockedUsePermitRegistry` 管理绑定会话的一次性 32-byte 许可。Broker IPC 通过 SCM_RIGHTS 验证原生 CLI client 并隔离 agent / guardian / Apple helper / observer / admin 角色；app agent 按连接管理租约与排空。安装入口保留认证 fallback 并登记当前用户的同团队组件。历史验证报告保留为研发证据，正常启用不以报告为门槛；完整故障矩阵仍需继续实测。详细边界见 [Locked Use](locked-use.md)。

## 关键边界

- 开源版当前不复刻官方闭源实现里的 caller signing、私有 IPC、完整 overlay choreography 和 plugin 自安装逻辑。
- 因为官方 `SkyComputerUseClient` 带有宿主侧 launch constraints，普通 stdio MCP client 在本机上可能被系统直接杀掉；如果要探测官方 bundled `computer-use`，`scripts/computer-use-cli` 的 app-server 模式现在只适合做工具清单和协议面观察。官方 `1.0.755` 的真实 tool call 还会经过 service-side sender authorization / active IPC client 追踪，外部 raw helper 即使走已签名 Codex binary，也可能返回 `Sender process is not authenticated`；需要真实使用官方工具时应走正常 Codex agent/tool 调用链，开源版则继续提供可直连的 `open-computer-use` MCP server。
- 当前权限引导已经具备可运行 app、深链、拖拽辅助，以及一版更接近官方的 accessory panel 入场动画和返回 affordance；点击链路也已经补上独立 visual cursor、官方 asset fallback 和相对目标 window 的排序逻辑，并且在 overlay 可见期间会持续重申“排在目标 window 之上”，避免用户手动激活目标 app 后 cursor 被目标窗口重新盖住；但整体还没有完全复刻官方那套嵌入式 choreography / host 集成 / session approval 体验。
- screenshot 当前通过 `ScreenCaptureKit` 捕获目标窗口，并以 MCP `image` content block 的 base64 PNG（默认）或配置的 JPG/WebP 返回，不再把普通 app 截图落盘到仓库或临时目录；编码前会按配置的最大长边等比例缩小，或按超限策略与最小总像素数门槛省略截图，同时 coordinate tools 继续按实际返回的 screenshot pixel 尺寸映射坐标；单次 ScreenCaptureKit capture 会设置超时，超时后省略 image block 而不是卡住整个 `get_app_state`。
- 会话状态现在是进程内内存态，保存每个 app 最近一次 snapshot 和 element index 映射。

## 主要验证路径

- 单元测试：`swift test`
- JS REPL 与 CLI contract：`node --test scripts/node-repl/*.test.mjs`
- standalone cursor 构建：`swift build --product StandaloneCursor`
- cursor lab 构建：`swift build --product CursorMotion`
- 端到端 smoke：`./scripts/run-tool-smoke-tests.sh`（标准 9-tool smoke + visual cursor idle smoke；脚本默认以 headless 模式启动内部 fixture，避免在用户桌面弹出测试窗口）
- app 打包：`./scripts/build-open-computer-use-app.sh debug`
- 权限 onboarding 端到端回归：`./scripts/run-permission-onboarding-e2e.sh`（需要当前 macOS 对被测 `open-computer-use` 已授予 Accessibility 与 Screen Recording；默认禁用 app-agent proxy 来测试当前 CLI 运行态，可用 `OPEN_COMPUTER_USE_E2E_CLI=/path/to/open-computer-use` 指定被测 CLI，或用 `OPEN_COMPUTER_USE_E2E_DISABLE_APP_AGENT_PROXY=0` 显式覆盖默认代理行为）
- npm staging：`node ./scripts/npm/build-packages.mjs`
- release tgz：`./scripts/release-package.sh`
- skill 打包：`npm run package:skill`
- Windows runtime 单测：`(cd apps/OpenComputerUseWindows && go test ./...)`（包含 `scroll` 请求必须携带 `windowBounds`、`global` 开关门控以及 runtime.ps1 全局输入守卫的回归用例）
- Windows exe 构建：`./scripts/build-open-computer-use-windows.sh --arch arm64`
- Linux runtime 单测：`(cd apps/OpenComputerUseLinux && go test ./...)`
- Linux binary 构建：`./scripts/build-open-computer-use-linux.sh --arch arm64`
- 对比样本：`artifacts/tool-comparisons/20260417-focus-behavior/`
- 手工诊断：
  - `open-computer-use doctor`
  - `open-computer-use snapshot <app>`
  - `open-computer-use call list_apps`
  - `open-computer-use call --calls '[{"tool":"get_app_state","args":{"app":"TextEdit"}}]'`

## 用户配置

macOS screenshot 在每轮捕获读取用户 JSON 配置，优先级为 ENV > 文件 > 默认值。npm launcher 提供 `ocu config` 查看、set、reset 和 path；支持 PNG/JPG/WebP、JPEG 质量、最大长边/超限缩小策略、最小总像素数丢弃与 SCK 超时，保留 hardware capture 优先路径。app-agent 按请求转发解析后的配置路径并清除未提供的 image 环境，防止常驻值污染。见[中文配置说明](configuration.zh-CN.md)与[English](configuration.md)。

截图像素丢弃门槛按 width×height 计算，低于（不含等于）门槛不返回 image，但保留 AX 和原因；配置省略截图后拒绝坐标输入。WebP 无损编码通过固定版本 libwebp 静态链接，随 app/npm 制品带上许可文本。

## 定向 AX 查询

macOS 在原有 9 个工具之外新增 `query`，按文字或角色查找目标窗口的 AX 元素，不截图、不渲染完整树。Windows/Linux 保持原来的 9 个工具。查询只解析已运行的应用，使用有界 BFS（默认 500 个节点、最多 5000 个，2 秒协作式遍历截止时间），返回匹配项和完整性元数据。字符串和子节点分页同样有界，AX 读取错误会标记结果不完整。

查询索引属于当前 native 会话，最多保留 5000 个、120 秒过期，结束会话时清理且永不复用。元素操作前核对进程身份、窗口归属、查询条件和最新几何；任何验证失败都要求重新查询，不使用旧坐标。JS `cua.getApp(name, { initialState: false })` 可跳过初始快照，`app.query()` 返回结构化结果。详见[查询说明](targeted-query.zh-CN.md)。

## 结构化权限查询

macOS `doctor --json` 在 CLI 和 app-agent proxy 路径复用 `PermissionDiagnostics`，只输出一份 JSON 快照，不打开 onboarding。字段为 `platform: "macos"`、`accessibilityTrusted`、`screenCaptureGranted`、`allGranted` 和 `missingPermissions`（`accessibility` / `screenRecording`）。缺权限仍退出 0，宿主应读取 `allGranted` 并重新查询授权变化。此状态延续系统 API/TCC 合并诊断语义，并非操作成功证明；Linux/Windows 明确拒绝该权限查询模式。普通 `doctor` 保留文本输出与权限引导。

Locked Use’s non-UI authorization mechanism is registered with `,privileged` and restricted to Apple's root authorizationhosthelper peers. A separate load-check right must return a fixed extractable context marker before the installer attaches the remote branch to system.login.screensaver; signature checks and a denied AuthorizationCopyRights result alone do not prove host compatibility. The original native fallback is preserved.

The load-check grants only its isolated right, with `shared=false` and a fresh AuthorizationRef that is destroyed afterwards. authd does not export context on a denied result. It reads/writes no credentials and never evaluates system.login.screensaver; successful marker export is required before installation changes that policy.
