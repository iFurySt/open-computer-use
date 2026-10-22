# 功能发布记录

## 2026-10

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-10-23 | macOS 截图编号与局部放大 | 视觉模型可直接按截图上的编号操作控件，也可放大窗口局部看清细节。 | `get_app_state` 新增 `marks` / `zoom`：在截图上用 element_index 标出可操作控件（与 click / set_value 同一索引，不新增索引），`zoom` 按窗口比例裁出局部并保留采集分辨率，坐标点击按放大图换算；沿用现有图片格式与尺寸配置，JS REPL 透传，Linux / Windows 明确拒绝。 |
| 2026-10-13 | Windows 滚动与坐标 | Windows 上 `scroll` 不再在默认配置下直接失败；150% 缩放且窗口位于屏幕右侧时，`get_app_state` 也能返回截图和窗口 bounds。 | 修复 `scroll` 请求漏传 `windowBounds` 导致坐标回退必然报 `No usable screenshot coordinates`；滚轮消息保留屏幕坐标并修正横向方向，PowerShell bridge 启动时对齐 DPI 物理坐标；`ScrollPattern` 在当前状态不可滚动时回退到坐标路径而不是让整个 tool call 失败。 |
| 2026-10-13 | Windows 全局输入兜底 | 需要真实指针或键盘的 Windows 动作（`click_method=global`、WinUI 键盘输入、子控件点击）在显式授权后可用，默认路径完全不变。 | Windows 实现 `click_method=global` 真实指针点击；`drag` / `scroll` 的坐标回退在 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 时使用真实指针，按键另需显式 `key_method=global`，`app_post` 仍保持 HWND 消息语义；未授权时在任何物理输入前拒绝，核对目标前台 / 命中 / 几何并在异常时释放输入。 |
| 2026-10-17 | 1.1.2 修复发布 | 软件光标持续跟随移动窗口，Linux 批量动作可减少回读开销，安装链接统一到新仓库。 | 同步所有版本源至 1.1.2；发布窗口锚点跟踪、Linux 动作回读配置与仓库改名后的 npm / 插件元信息，沿用既有命令和 App 签名身份。 |
| 2026-10-17 | 仓库名称统一 | 项目地址与现有 npm 包、CLI 和 App 名称保持一致，方便多个 Agent 使用。 | 仓库迁移到 `iFurySt/open-computer-use`，同步当前安装说明、npm / plugin 元信息与发布模板；保留原有包名、命令、App 签名身份和历史发布链接兼容。 |
| 2026-10-17 | macOS 文本选择 | Agent 可选中文字或放置光标，不必模拟拖拽。 | 新增 native select_text 和 JS app.selectText，支持快照 / query 索引、前后文消歧和 UTF-16 选区；重新检查会话与文本，验证失败明确报错，关闭完整回读时仍验证实际选区。 |
| 2026-10-17 | macOS 软件光标窗口跟随 | 目标窗口移动后，行进、点击反馈和等待中的软件光标继续跟随，避免停在旧位置。 | 接入窗口相对锚点，修复 idle / pulse 的旧落点、行进中止后的可见位置及重复计时器；AX 帧读取改为后台串行缓存，限制为最多 30 Hz / 一个请求，并在清理时释放追踪。 |
| 2026-10-15 | 1.1.1 修复发布 | Locked Use 安装更新更可靠，降低认证与后台 IPC 开销。 | 统一版本为 1.1.1，发布授权宿主、安装加载检查、旧组件卸载与连接生命周期修复；完整双屏遮罩、自动解锁、点击验证和重锁实测通过。 |
| 2026-10-15 | Locked Use 安装与性能修复 | 减少认证和 IPC 开销，旧系统组件也能正常移除并重装。 | 非 UI 插件使用 privileged host，安装前验证真实加载；修复系统缓存卸载与转交 socket 的生命周期，降低空闲唤醒，status 提示组件版本差异。 |
| 2026-10-15 | Linux 动作回读 | REPL 批量操作可省去每个动作后被丢弃的完整界面观察。 | Linux 开始支持现有的 `OPEN_COMPUTER_USE_ACTION_READ_BACK=0`，成功动作返回 `ok`，保留最后一次显式观察的索引缓存；默认原生 MCP 回读与显式 `get_app_state` 保持不变。 |
| 2026-10-15 | Linux 焦点与选区 | 大型界面减少重复查找，预算不足时明确提示，选中文字能正确返回。 | 复用快照已选窗口，一次查找生成焦点摘要与选区；按节点和深度预算停止读取，使用标准 AT-SPI 选区接口，并补隔离 GTK 验证。 |
| 2026-10-15 | Linux 隐藏控件详情 | 隐藏节点较多时，可减少不需要的属性读取。 | 新增默认关闭的 `OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN`；保留节点、索引和可见子节点，状态未知时完整读取，补充真实 GTK 标签页及 native MCP 回归。详见 [使用与验证](../linux-hidden-details.md)。 |
| 2026-10-15 | 按需观察 | 只需控件信息时可省去截图，只需画面时可省去 AX 遍历。 | 统一 macOS / Windows / Linux 的 include_ax / include_screenshot、JS 和 CLI snapshot 参数，默认完整采集；纯截图清理旧索引，只取 AX 拒绝截图坐标输入，补真实 AppKit / GTK / WPF、Windows 截图边界与 PowerShell 分支验证。详见 [使用与验证](../selective-observation.md)。 |
| 2026-10-14 | 1.1.0 正式发布 | 用户可直接安装 Locked Use，在锁屏遮罩期间继续 GUI 操作，也可用定向查询和持久截图配置减少工具开销。 | 统一版本为 1.1.0；签名 universal macOS App 内嵌服务、Guardian、安装器和授权插件，普通 enable 请求权限，补齐冷启动握手隔离和发布制品检查；新增 app.query()、doctor --json 与 ocu config。 |
| 2026-10-10 | macOS Locked Use 验证版 | 可在已登录 Mac 锁屏时，通过全屏遮罩继续 GUI 自动化，并在结束或本地接管后安全重锁。 | 正式组件采用 OCU Guardian / OCULockService / OCULockInstaller / OCULockAuth 短名称，开发 App 保留 Dev 区分；新增签名 Broker / 授权插件、双进程显示器保护、一次性许可、租约排空 / 恢复及构建和实机验证脚本；管理员显式启用 validation profile，生产 backend 在完整验证前保持关闭。 |
| 2026-10-10 | macOS 定向 AX 查询 | 知道控件文案时，可以直接查询并操作，不必先获取截图和完整 AX tree。 | 新增 native `query` 和 JS `app.query()`，按文字、角色和窗口查找元素，返回完整性元数据；查询索引仅在同一会话内有效，操作前重新验证目标和位置。 |
| 2026-10-10 | macOS 截图配置 | 普通用户可用 `ocu config` 持久化截图偏好，无需维护 shell ENV。 | 新增用户 JSON、ENV 覆盖、PNG/JPG/WebP 格式、明确的超大缩小/丢弃开关、最小总像素数过滤、质量/SCK 超时；取消字节预算缩小，支持关闭长边上限，省略截图时说明原因，保留 #65 捕获路径与坐标映射。 |
| 2026-10-10 | 结构化权限查询 | 宿主可以读取和轮询 macOS 授权状态，无需解析文本或重复弹引导。 | 新增 `ocu doctor --json`，输出权限布尔值、`allGranted` 和缺失权限列表；普通 `doctor` 保留权限引导，Linux/Windows 明确返回不支持。 |
| 2026-10-10 | 1.0.0 正式发布 | 用户可通过 npm 或直接下载使用跨平台桌面自动化，并以持久 JavaScript 会话编排操作。 | 基于当前 main 发布 `1.0.0`：统一所有版本源，交付 macOS 后台键盘、遮挡/其他 Space 窗口读取及显式 agent display，包含 Linux 快捷键与 Windows 无效截图修复；Linux / Windows runtime 继续标为实验性。 |
| 2026-10-09 | Linux 按键 | Linux 上 `press_key` 的 Enter、Tab、Escape、方向键和 `ctrl+a` 等快捷键会送达正确的按键，Agent 可以提交表单、切换焦点和使用快捷键。 | Linux bridge 改用 `KeySynthType.SYM` 发送具名键 keysym，并以 `LOCKMODIFIERS` / `UNLOCKMODIFIERS` 保持修饰键；此前 keysym 被当作 keycode，Enter 会输入 `4`，修饰键不生效。 |
| 2026-10-09 | Windows 截图可靠性 | 极小、最小化、隐藏、cloaked 或离屏窗口不会再向模型返回不可用的 PNG；极端情况下仍可读取 accessibility tree，并明确限制依赖截图坐标的操作。 | Windows bridge 在截图前校验窗口状态、virtual screen 交集和最小尺寸，Go 层再次解码 PNG header 复核；无有效截图时省略 image block，coordinate click / drag fail closed，不做放大、补边或占位图。 |

## 2026-09

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-09-29 | 跨平台分发与 JavaScript 自动化 | Agent 可以通过持久 JavaScript 会话批量编排桌面操作，延迟异步错误不会污染下一次调用；DSH 用户获得一键兼容安装；不使用 npm 或 Homebrew 的用户也可直接下载三端 runtime 和 skill。 | 发布 `0.3.6`：新增 plugin `js` / `js_reset`、`ocu js` / `ocu repl`、DSH 验证式安装，并在 tag CI 完成后统一发布 macOS universal app、Linux / Windows 双架构 CLI、skill、SHA-256 校验和与 manifest。 |
| 2026-09-24 | macOS 后台操作收敛 | assistant turn 或 MCP/REPL connection 结束时会自动恢复窗口与 occlusion 状态；JS API 可直接传 `windowPlacement` 和 `keyMethod`。 | `restore` 改为按 app 恢复当前 runtime 停放的全部窗口；`get_app_state` 不再错误标为 read-only；私有 `CGVirtualDisplay` API 变化会 fail closed 而不是以 Objective-C exception 终止 host。一次性 CLI 的 park/action/restore 需放在同一个 `call --calls` 中。 |
| 2026-09-22 | JS REPL CLI | 用户无需先配置 MCP host，也可以直接用 `ocu js` 执行一次性 Computer Use JavaScript，或用 `ocu repl` 在终端中复用持久 binding；Agent 还能先读取结构化 capability 状态。 | npm launcher 新增 positional/stdin/file 三种 `js` 输入、持久 terminal REPL、`capabilities [--json]` 和稳定 help availability；`ocu mcp` 仍保持原生 9-tool surface。 |
| 2026-09-22 | JS REPL 错误传播与 read-back | `js` 代码抛出的异常立即以 `isError` 返回且保留 bindings，不再等到 30 s 超时并丢弃 session；macOS 上一批 action 不再为每个动作等待 150 ms 并重新读取整棵 AX tree，十次点击从数秒降到约一次 state read。 | REPL adapter 从 Node 的 `handleError`（Node 26）或 domain（Node 22）路径 settle 当前 evaluation；adapter 以 `OPEN_COMPUTER_USE_ACTION_READ_BACK=0` 启动 native runtime，macOS action 在该模式下返回短状态、跳过 settle 与 snapshot；默认 9-tool 行为不变，Linux / Windows 暂时忽略该变量。 |
| 2026-09-21 | JS REPL Computer Use | Agent 可以用异步 JavaScript 绑定 app，并在一个 tool round trip 内完成 inspect、action、条件和最终验证，不必在多轮间搬运所有中间状态。 | Codex plugin 通过持久 Node.js Worker 和 app-bound `cua` API 暴露 `js` / `js_reset`；`open-computer-use mcp` 继续保留既有 9-tool compatibility surface。 |
| 2026-09-17 | DeepSeek Harness 集成 | DSH 用户可以用一条命令安装 Open Computer Use，并在写入配置前发现错误的可执行文件或不兼容的 MCP server。 | 新增 DSH MCP 兼容安装器、turn-boundary 光标清理 hook 和非破坏性 skill 安装；安装前校验 server identity 与非空工具目录但不锁死工具数量，显式安装在 MCP 启动失败时 fail loud，并明确该路径不注册 DSH 的 first-class computer-use provider。 |
| 2026-09-10 | macOS 拖拽修复 | 显式开启全局指针路径后，窗口移动、文本拖选与 Finder 拖放可收到启动真实拖拽所需的事件；默认路径的限制也会明确呈现。 | 发布 `0.3.5`：补齐拖拽位移、手势事件编号与 HID 投递时序，增加投递路径说明；同步升级 Go MCP SDK 到 `v1.4.1`。 |
| 2026-09-08 | macOS agent display | 已经被遮挡或在其他 Space、内容被 app 隐藏的窗口，可以显式停靠到 agent 专用的不可见显示器上读取、点击和输入，用户的 Space、焦点、指针不受影响，用完可恢复原位。 | `get_app_state` 新增 `window_placement`（`keep` / `agent_display` / `restore`）：通过 `CGVirtualDisplay` 创建 agent 显示器并用 AX 位置移动窗口 frame，`restore`、MCP server 正常关闭或进程退出时移回并销毁显示器；失败时保留恢复记录供重试；Windows / Linux 返回 unsupported。 |
| 2026-09-08 | macOS 被遮挡 / 其他 Space 窗口 | `get_app_state` 不再为其他 Space 的窗口激活或抬升应用；先看过一次的 Chromium / Electron 窗口在被遮挡或切换 Space 后仍能读到网页内容和实时截图；`sky_click` 可以点击被遮挡或其他 Space 的窗口。 | 窗口解析退到所有窗口列表；拍到未被遮挡的窗口后关闭其 WindowServer occlusion 通知，保存并在 MCP server 正常关闭或进程退出时恢复原始状态；Chromium 系 app 懒加载 AX tree 时最多重走 3 秒；`sky_click` 校验只要求窗口仍属于目标进程。 |
| 2026-09-08 | macOS 后台键盘输入 | Agent 可以向被遮挡或位于其他 Space 的 Chromium / Electron 窗口输入文字和快捷键，用户当前的应用、焦点、指针和 Space 都不受影响。 | 为 `type_text` / `press_key` 新增 `key_method`，提供 `auto`（默认）和 macOS-only 的 `sky_key`：复用 `sky_click` 的 target-only synthetic focus，加上 make-key-window record 让目标窗口在其进程内成为 key window，`cmd` 组合键改走目标菜单栏。Windows / Linux 返回稳定 unsupported。 |
| 2026-09-08 | drag 投递路径可见性 | 在默认安全配置下调用 `drag` 做窗口移动、文本拖选或 Finder 拖放时，结果会明确说明事件只投递给目标进程、为何没有效果，以及需要设置哪个环境变量，不再表现为“成功但无效果”。 | `drag` 结果新增一条 `Drag delivered via app_post` / `Drag delivered via global pointer path` 文本项；tool description 补充默认路径限制与 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 说明；skill 文档新增 Drag Delivery 章节；默认行为与安全门本身不变。 |
| 2026-09-08 | macOS 应用定位与 secondary action | 按名称定位应用时减少误选后台 helper，执行 secondary action 时避免动作错配。 | 发布 `0.3.4`：优先匹配普通应用；支持 Safari custom action 短名称，并修复过滤后的动作映射和名称冲突。 |
| 2026-09-06 | macOS secondary action | Agent 可以通过 Safari 暴露的 `close tab` secondary action 可靠关闭标签页，不会因内部动作被过滤而误执行另一项动作。 | macOS renderer 将 `Name:close tab ...` 形式的 AppKit custom action descriptor 显示为短名称，executor 从同一组过滤后的 raw actions 做等价名称匹配，并拒绝歧义匹配；短名称与其他原始 action 冲突时保留完整 descriptor，避免误执行同名原始动作。 |
| 2026-09-06 | macOS 应用名称解析 | 按名称定位 Safari 等应用时优先匹配真实应用，避免同名后台 helper 抢占匹配结果。 | 按普通应用名称、普通应用 executable、后台应用名称、后台 executable 分级匹配；同级保持原顺序，bundle identifier 和安全过滤规则不变。 |
| 2026-09-01 | 内嵌 App Agent Socket 隔离 | 使用内嵌 OCU 的宿主不会再与用户全局 OCU 争用同一个 App Agent Socket，避免一个实例意外终止或替换另一个实例。 | 发布 `0.3.3`，为显式配置 namespace 的宿主生成确定性、短且不泄露原值的 Socket 文件名；未配置时继续兼容旧路径。 |

## 2026-08

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-08-29 | 跨平台文本与 Web 链接动作 | Linux 用户在 Ubuntu 24.04 等环境中可稳定使用文本操作；Chrome / BOSS 中的导航链接也能保持独立定位与点击。 | 发布 `0.3.2`，通过标准 AT-SPI 接口检测文本能力，并保留带 URL 的 Web 链接动作节点，避免父级通用动作吞掉链接语义。 |
| 2026-08-08 | Linux AT-SPI 文本能力检测 | Ubuntu 24.04 等 PyGObject 环境中的 `get_app_state`、`type_text` 和 `set_value` 不再因缺少非标准 `Accessible.is_text` / `is_editable_text` 属性而崩溃。 | Linux bridge 改为通过标准 `Accessible.get_interfaces()` 检测 `Text` / `EditableText`，并新增不依赖真实桌面的 Python 回归测试。 |

## 2026-07

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-07-30 | Web 可点击选项边界 | Chrome 等 Web 页面中的多个文本选项即使位于同一个摘要容器内，也能分别保留可操作的 `element_index`；BOSS 直聘转发弹窗中的“站内同事”“转发至其他”和“邮件转发”可以被独立定位。 | 发布 `0.3.1`，让带 `AXPress`、`AXConfirm` 或 `AXOpen` 的紧凑通用节点成为文本摘要边界并渲染为 `button`；普通纯文本压缩以及零尺寸、大面积通用节点过滤保持不变。 |
| 2026-07-27 | 可配置与后台点击 | 调用方可以显式选择点击实现，并在 macOS 上对被遮挡的同 Space 窗口执行后台点击，同时保持真实鼠标、前台应用、窗口焦点和层级不变。 | 发布 `0.3.0`，为 `click` 新增 `click_method`，提供 `auto`、`accessibility`、`app_post`、`global` 和 macOS-only `sky_click`；默认 `auto` 行为保持不变，显式模式失败时不静默切换实现，`global` 继续要求环境授权。 |
| 2026-07-20 | 匿名 Web 图标控件 | Chrome 等 Web 页面里的纯图标按钮即使没有可读名称，也能在 snapshot 中保留可点击的 `element_index`，Agent 可以更稳定地操作 icon-only 控件。 | 发布 `0.2.1`，保留具有 `AXPress` / `AXConfirm` / `AXOpen` 主动作且 frame 紧凑有效的匿名 `AXGroup` / `AXUnknown`，渲染为 `button`；同时继续过滤零尺寸节点和大面积通用点击容器。 |
| 2026-07-08 | 快照预算与长文本控制 | 长网页、长列表和复杂表格可以显式提高 accessibility tree 预算，读取长消息或文档时也能按需选择更大的文本上限或全文模式。 | 发布 `0.2.0`，三端默认 tree budget 统一为 1200/64，并为 `get_app_state` / `snapshot` 增加 `max_tree_nodes`、`max_tree_depth` 与 `text_limit` / `--text-limit`；`show_full_text` / `--show-full-text` 已由 `text_limit: "max"` / `--text-limit max` 替代。 |

## 2026-06

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-06-26 | npm CLI 短别名 | npm 全局安装后可以直接使用 `ocu` 作为 `open-computer-use` 的短命令，常用的 `ocu mcp`、`ocu call ...` 和 `ocu install-codex-mcp` 更适合日常输入。 | 发布 `0.1.54`，npm staging 包新增 `bin/ocu` 并复用现有 launcher；同步 README、skill 指引、CI/CD 说明和 release staging 检查，确保后续发版会验证短别名。 |
| 2026-06-11 | 快照长文本与 Windows 编码稳定性 | `snapshot` / `get_app_state` 默认文本截断在 macOS、Linux、Windows 上保持一致；需要读取完整长消息时可以显式打开 full-text 模式。Windows runtime 处理中文等非 ASCII tool 参数和 MCP 输出也更稳定。 | 发布 `0.1.53`，新增 `show_full_text` / `--show-full-text`，默认统一 500 字符并追加 `...`；修复 Windows operation JSON 读取和 PowerShell 输出编码；同时补 agent smoke 与 stress 验证脚本。 |
| 2026-06-03 | CLI element index 容错 | 手写 `open-computer-use call` JSON 时，`element_index` 写成数字也能正常点击、滚动或设置值，不再因为 JSON 数字类型被误认为缺少索引。 | 发布 `0.1.52`，macOS Swift dispatcher 与 Windows / Linux Go runtime 统一把整数型 `element_index` 规范化为字符串，同时继续拒绝空值和小数，并同步测试、skill 示例和 history。 |

## 2026-05

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-05-20 | macOS 权限完成态 | 已经完成 Accessibility / Screen Recording 授权后，权限引导浮层会根据当前运行进程的真实 preflight 状态及时退出，不再因为 stale TCC path 查询结果继续悬浮。 | 发布 `0.1.51`，`PermissionDiagnostics.current()` 合并 TCC 持久授权与 runtime preflight 正信号，并新增本机端到端脚本覆盖 `doctor` 已 granted 时 onboarding 快速退出的路径。 |
| 2026-05-13 | macOS 点击与输入稳定性 | 飞书 / Lark 会话列表点击不再误触右侧“完成”动作，中文、emoji 等富文本输入更稳定；同时 Chrome/GitHub 这类普通浏览器页面的 container/link 点击保持原有行为不退化。 | 发布 `0.1.50`，macOS `type_text` 按 grapheme cluster 批量投递 Unicode，并在 Electron 可设置输入框上优先写 `AXValue`；点击链路增加 synthetic row 左侧安全锚点、side action 过滤和 Electron-scoped 行级 `AXPress` 优化，同时用 Chrome/GitHub pinned repo 对照验证避免浏览器 WebArea 退化。 |
| 2026-05-11 | macOS 文件选择弹窗 | 上传/打开文件弹窗里右侧文件列表现在可被读取和点击，选择图片后 Open 按钮能正常触发，不再只能操作左侧目录。 | 发布 `0.1.49`，macOS AX snapshot 补上 `AXContents` / `AXVisibleChildren` 遍历，coordinate click 优先选择原生 `AXList` 子项，并让截图窗口在重叠 sheet 场景下优先绑定前台 open panel；补对应单元测试和 history。 |
| 2026-05-08 | MCP 结果大小控制 | Chrome / Electron 等复杂窗口返回截图时更不容易触发 Codex 的大结果降级，历史记录和上层工具消费里会继续保持正常的 `text + image` 结构，而不是把整个 MCP result 塞进 text 字符串。 | 发布 `0.1.48`，macOS `ScreenCaptureKit` 截图在编码为 MCP image block 前会按最大尺寸和目标字节数自适应缩小，并补测试锁住大图压缩、小图保真路径。 |
| 2026-05-08 | Smoke 测试静默运行 | 开发者运行 `./scripts/run-tool-smoke-tests.sh` 时不再被内部 fixture 的橙色测试窗口打断，回归验证更安静，也不会让用户误以为桌面上弹出了额外应用。 | 发布 `0.1.47`，smoke suite 默认以 headless 模式启动内部 fixture，并保留 fixture 在 `list_apps` smoke 路径里的可发现性。 |
| 2026-05-07 | 窗口不可用错误文案 | Lark / Chrome 等 no-window 场景下，开源版 `get_app_state` 的返回文本与官方 `computer-use` 当前输出一致，减少上层 prompt、测试和用户排查时的差异噪音。 | 发布 `0.1.46`，将 missing AX window 和 missing visible CGWindow 两条路径统一为 `Apple event error -10005: cgWindowNotFound`，并补单元测试锁住该官方风格文本。 |
| 2026-05-07 | 可见窗口匹配 | `get_app_state` 在 app 没有可见窗口、窗口已最小化，或 AX 窗口无法匹配到 on-screen CGWindow 时会更接近官方 `computer-use` 的 `cgWindowNotFound` 语义，避免返回没有截图坐标基础的半残状态。 | 发布 `0.1.45`，基于官方 `1.0.770` 逆向字符串中的 `cgWindowNotFound`、`noWindowsAvailable`、`matchingWindowNotFound` 和 `AXWindowMiniaturized` 线索，要求真实 app snapshot 同时满足未最小化 `AXWindow` 与可见 `CGWindow`。 |
| 2026-05-07 | 无可用窗口状态对齐 | 当 Lark / Feishu 这类 app 暂时没有可用 AX 窗口时，`get_app_state` 会明确返回不可用错误，不再输出只有 application / menu bar 的误导性树，后续工具不会拿到不可操作的 element index。 | 发布 `0.1.44`，对 focused window 和 first window 候选做 `AXWindow` 角色过滤，并要求真实 AX window 才渲染 accessibility tree；该行为与官方 `computer-use` 在相同 Lark 状态下的失败语义对齐。 |
| 2026-05-07 | WebArea 状态树结构 | Feishu / Lark 这类 Electron app 的 `HTML 内容` 区域会保留更接近官方 `computer-use` 的浅层 layout container 和分支结构，减少过度扁平化，便于后续按上下文定位消息、公告和输入区域。 | 发布 `0.1.43`，基于官方 `computer-use` `1.0.770` 对比和二进制字符串线索调整 WebArea generic wrapper elision：保留浅层容器和深层分支容器，同时继续压缩深层单子链噪声。 |
| 2026-05-07 | Electron 状态树细节对齐 | Feishu / Lark 消息列表里带头像或图片的紧凑行更接近官方 `computer-use`，会保留 `container -> text + image` 结构，后续点击和读树时更容易定位图片子节点。 | 发布 `0.1.42`，在短文本摘要容器含 image descendant 时将摘要渲染成 synthetic child text，并保留最多四个 image 子节点；补充 Lark 对比采样和单元测试。 |
| 2026-05-07 | Electron 状态树对齐 | Feishu / Lark 这类 Electron app 的 `get_app_state` 更接近官方 `computer-use`：消息列表、聊天输入框、侧边栏、菜单栏和 WebArea URL 会同时保留，内部图片资源 URL 不再泄漏到可读树里。 | 发布 `0.1.41`，结合官方 app 逆向线索启用 Electron accessibility 模式，调整 AX 遍历去重、短文本合并、menu bar 渲染、boolean tab 和 image/WebArea 格式，并补充 Feishu 对比验证。 |
| 2026-05-07 | Feishu / Electron 状态稳定性 | Feishu 这类 Electron/WebView app 的 `get_app_state` 更容易返回可操作的消息内容和输入框，不再只给截图却缺 UI tree 关键节点；截图捕获异常时也不会卡住整个状态读取。 | 发布 `0.1.40`，放宽 macOS AX tree 深度预算，压缩空 wrapper、过滤 `AXScrollToVisible` 和空字符串噪音，并为 ScreenCaptureKit 截图增加超时；同时让 smoke suite 直测当前构建产物。 |
| 2026-05-07 | macOS app 安全边界 | Chrome、终端、Atlas 和系统组件不再被硬编码 denylist 拦住，常规 app 自动化路径更少误伤；密码管理器仍保持内置阻止。 | 发布 `0.1.39`，将 macOS `AppSafetyPolicy` 收缩到 1Password、Bitwarden、Dashlane、LastPass、NordPass 和 Proton Pass，并同步测试、架构和安全文档。 |
| 2026-05-06 | npm 安装后的 app-agent 启动 | `npm install -g open-computer-use` 后，`open-computer-use doctor` 不会再因为本机残留旧 staging `.app` 而启动错副本并超时。 | 发布 `0.1.38`，当当前进程已经来自合法 `Open Computer Use.app` bundle 时，代理启动优先复用正在执行的 bundle，再回退到 LaunchServices / 标准安装目录发现的其它副本。 |
| 2026-05-06 | macOS 权限身份 | macOS 用户重新安装新版 npm 包后，只需要授权 `Open Computer Use.app`，不再要求给 iTerm / Terminal 单独授予 Accessibility 或 Screen Recording。 | 发布 `0.1.37`，将 `mcp`、`doctor`、`call`、`snapshot` 和 `list-apps` 通过 LaunchServices 启动的 app-agent 执行，让真实 AX / ScreenCaptureKit 调用落在 `.app` 权限主体上，并同步更新权限文案和版本源。 |

## 2026-04

| 日期 | 功能域 | 用户价值 | 变更摘要 |
| --- | --- | --- | --- |
| 2026-04-23 | Linux Codex MCP 安装 | Linux 用户现在可以按 `npm i -g open-computer-use`、`open-computer-use install-codex-mcp`、`codex` 的路径接入，不再手动编辑桌面 session 的 D-Bus / display 环境变量。 | 发布 `0.1.36`，Linux runtime 在启动 AT-SPI bridge 前会动态发现当前用户的 `/run/user/<uid>` session bus 和 display / Wayland 环境，Codex 配置继续保持 `open-computer-use mcp`。 |
| 2026-04-23 | 三端 npm 安装 | `npm i -g open-computer-use` 现在会根据当前 `os-arch` 调用对应的 macOS `.app`、Linux binary 或 Windows `.exe`，不再把 npm 分发锁死在 macOS。 | 发布 `0.1.35`，三个既有 npm 包都会内置 macOS、Linux、Windows runtime，由跨平台 Node launcher 选择 native runtime；`0.1.34` 的新增 platform package 方案因 npm 包名权限失败后被 supersede。 |
| 2026-04-22 | Gemini / opencode MCP 安装 | Gemini CLI 和 opencode 用户现在也能像 Claude Code / Codex 一样用仓库内置命令完成 `open-computer-use` 的 MCP 接入，不需要再手动查各自配置格式。 | 发布 `0.1.33`，新增 `install-gemini-mcp` 和 `install-opencode-mcp`，将 npm launcher、README 与共享配置 helper 一并补齐，并让 Gemini 默认 project-scope 配置不会污染仓库 git 状态。 |
| 2026-04-22 | 发布版本重新对齐 | GitHub Release tag、插件 manifest 和仓库内版本常量重新回到同一个版本线；后续本地安装、staging 和诊断不会再出现 “release 已是新版本，但产物仍显示旧值” 的混乱状态。 | 发布 `0.1.32`，在远端 `v0.1.31` 已存在的前提下，将 `plugin.json`、Swift 版本常量、smoke/test 初始化请求和 CLI helper 文档统一 bump 到 `0.1.32`，为下一次 release 保持单一版本源。 |
| 2026-04-22 | 视觉光标落点与空闲态收口 | Retina 窗口里的坐标点击更准确，visual cursor 在等待下一次动作时也更稳定、更接近官方观感。 | 发布 `0.1.31`，修复 screenshot pixel 到 window point 的映射，避免 `click({x,y})` 在高分屏上点偏；同时把 idle cursor 收敛为 30 秒停驻、保持压在目标窗口之上，并将等待态改成 anchored tip + tiny rotate wobble。 |
| 2026-04-22 | Windows runtime 预览与发版说明 | Windows 用户和后续开发者现在有了实验性 Computer Use runtime 起点；每次 GitHub Release 也会保留面向用户的变更摘要，不再只留下 changelog 链接。 | 发布 `0.1.30`，新增实验性 Go/PowerShell Windows runtime、构建脚本和文档；同时明确 release agent 在 bump 版本后必须检查 GitHub 自动 release notes，必要时手动补 `What's Changed`。 |
| 2026-04-22 | click 定向 fallback | 当目标 app 的 Accessibility 点击链路不完整时，`click` 现在会先尝试定向发送鼠标事件，不会立刻抢走用户真实鼠标；Finder 侧边栏这类场景也更容易真正点通。 | 发布 `0.1.29`，补上 `click` 的 `AX -> pid-targeted mouse event -> optional global pointer fallback` 顺序，优先尝试 `AXPress` / `AXConfirm` / `AXOpen`、子孙点击候选和命中点附近 hit-test，再把全局物理指针保持为显式 opt-in 的最后兜底。 |
| 2026-04-22 | 软件光标移动速度 | `click` / `set_value` 的 overlay cursor 默认移动速度不再显得过快，和 `Cursor Motion` 默认档及官方 spring endpoint-lock 时间保持一致。 | 发布 `0.1.28`，移除 runtime 里旧的距离压缩时长公式，默认 move 直接使用已恢复出的 `response=1.4` / `dampingFraction=0.9` / `dt=1/240` close-enough 时间 `343 / 240 = 1.4291667s`，并补回归测试和逆向文档。 |
| 2026-04-22 | Computer Use 工具对齐收口 | 9 个 Computer Use tools 的 schema、错误语义和默认非侵入输入路径进一步贴近官方；`press_key` 支持更多 xdotool alias。 | 发布 `0.1.27`，收口剩余工具 checklist：`perform_secondary_action` invalid action 错误改为官方形态，fixture `Raise` 不再准备全局物理指针输入，`press_key` 补齐 `BackSpace`、`Page_Up`、`Prior` / `Next`、`F1...F12` 和常见 `KP_*` alias，并把 execution plan 进度项具体化。 |
| 2026-04-22 | Computer Use 操作连续性 | 连续 `click` / `set_value` 不再反复从左下角 fresh cursor 起步，任务结束时也能显式清理 overlay；`scroll` / `drag` 默认路径进一步避免移动用户真实鼠标。 | 发布 `0.1.26`，基于官方 bundled app 复查把 visual cursor 改成约 5 分钟 idle 保留并接入 `turn-ended` 清理，同时将 `scroll.pages` 对齐为 number schema、required string 空值按 missing 处理，并把 `scroll` / `drag` 默认 fallback 改为 pid-targeted event。 |
| 2026-04-22 | set_value 可设置边界 | `set_value` 对 Sublime 这类不可直接设置的文本区域会返回清晰的 non-settable 错误，不再暴露底层 `-25200`。 | 发布 `0.1.25`，按官方 bundled app 的 settable accessibility element 语义，在写入前检查 `AXUIElementIsAttributeSettable(kAXValueAttribute)`，不可设置时不退到键盘、剪贴板或未公开文本替换接口。 |
| 2026-04-22 | click 非侵入默认行为 | `click` 的 AX 失败路径不再默认移动用户真实鼠标，多次点击也会优先复用可用的 AX action。 | 发布 `0.1.24`，基于官方包 click/EventTap 逆向结果，将全局物理指针 fallback 改成 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 显式 opt-in，并修正 `click_count > 1` 直接落入全局鼠标路径的问题。 |
| 2026-04-21 | CLI tool 编排 | 不接 MCP client 时也能直接通过 `open-computer-use call` 调用 9 个 Computer Use tools，并能用 JSON 数组在同一进程里编排连续动作。 | 发布 `0.1.23`，新增原生 `call` 子命令、共享 MCP/CLI tool dispatcher、`--calls` / `--calls-file` 序列执行和相关文档测试。 |
| 2026-04-21 | 软件光标运行时朝向 | 软件光标首次出现和移动时的可见朝向更贴近官方行为，上行、转向和落点姿态不再出现坐标系翻转造成的违和感。 | 发布 `0.1.22`，修正 runtime overlay 在 AppKit 全局坐标与 Cursor Motion y-down screen state 之间的速度/朝向转换，并补充回归测试锁定首次 `(0,0)` 起点和 render rotation 关系。 |
| 2026-04-21 | 软件光标视觉一致性 | `click` / `set_value` 期间显示的软件光标更接近 Cursor Motion 的参考渲染，首次出现、移动朝向和正式 app icon 的视觉边界更稳定。 | 发布 `0.1.21`，把 runtime overlay 切到共享的程序化 glyph renderer，修正初始朝向和 runtime 绘制方向，并同步收口 Open Computer Use app icon 的安全边距。 |
| 2026-04-20 | 安装器宿主依赖 | `open-computer-use install-codex-plugin` 不再额外依赖 `rsync`，插件安装路径更接近“只要 npm/Node 已可用就能跑”。 | 发布 `0.1.20`，把 plugin installer 里复制 plugin 目录和 `.app` bundle 的实现从 `rsync` 改成 Node `cpSync`，继续收口 `open-computer-use` 的安装器运行时前提。 |
| 2026-04-20 | 安装器运行时依赖 | `open-computer-use` 的一键安装命令不再因为系统 Python 版本太旧而失败，npm 全局安装后的首次接入路径更稳定。 | 发布 `0.1.19`，移除 `install-claude-mcp`、`install-codex-mcp`、`install-codex-plugin` 对 `python3` / `tomllib` 的运行时依赖，统一改为随 npm 包分发的 Node helper 处理配置读写。 |
| 2026-04-20 | macOS 分发签名与公证 | `Cursor Motion` 的下载 `.dmg` 现在补齐了 Apple notarization 要求的 hardened runtime，release 链路离标准 macOS 分发更近了一步。 | 发布 `0.1.18`，修复 `Cursor Motion.app` 在 notarization 前缺少 hardened runtime 的问题；Developer ID 签名现在会显式启用 `codesign --options runtime`，用于新的 release 重跑。 |
| 2026-04-20 | macOS 分发签名与公证 | `Open Computer Use` 的 release `.app` 已经能走统一的 `Developer ID Application` 签名链，`Cursor Motion` 的公证工作流与演示视频入口也已接入仓库。 | 发布 `0.1.17`，接通 `Developer ID Application` 证书导入、统一签名和 `Cursor Motion` 的 notarization 工作流，README 也补了 `Cursor Motion` 的演示视频入口；但该版本的 `Cursor Motion` `.dmg` 仍因缺少 hardened runtime 未通过 Apple notarization。 |
| 2026-04-20 | Open Computer Use 开发态身份 | 本地 debug/dev 调试构建不再和正式发布版在系统权限列表里混成同名对象，开发授权与正式分发边界更清楚。 | 发布 `0.1.16`，CI release 回退到原来的 ad-hoc 打包路径，不再要求 GitHub Actions 导入开发证书；本地非 release 构建统一改成 `Open Computer Use (Dev).app` 和 `com.ifuryst.opencomputeruse.dev`，权限发现也会在 dev 运行态优先绑定当前 dev app。 |
| 2026-04-20 | Open Computer Use 权限身份 | 从 npm、brew、DMG 或本地构建安装后，`Open Computer Use.app` 的权限身份现在更容易收口到同一条签名链，不会再默认把 npm 路径当成唯一稳定授权目标。 | 发布 `0.1.15`，给 `Open Computer Use.app` 的打包链路补上统一 codesign 入口，CI release 支持通过 GitHub Actions secrets 导入证书后统一签名；权限发现也改成按 bundle identity 搜索当前运行副本、`/Applications`、npm 和 Homebrew 安装位置。 |
| 2026-04-20 | Cursor Motion 打包一致性 | Releases 里的 `CursorMotion.dmg` 现在会和 `swift run CursorMotion` 更一致，不再因为缺少官方 cursor 资源而退回更锯齿、朝向也更差的 fallback glyph。 | 发布 `0.1.14`，修复打包 `.app` 时没有把官方 `official-software-cursor-window-252.png` 带进 bundle 的问题；`Cursor Motion` 现在会优先从 `Bundle.main` 读取这张图，DMG 打包脚本也会把它复制进 `Contents/Resources`，并显式打开高分屏渲染。 |
| 2026-04-20 | Cursor Motion 与发版链路 | Cursor Motion 作为独立 demo 的命名和入口更统一，同时 release tag 现在可以直接产出可下载的 macOS `.dmg`。 | 发布 `0.1.13`，把 `StandaloneCursorLab` 统一更名为 `Cursor Motion` / `CursorMotion`，同步中英文 README 与架构文档，并新增 tag 驱动的 `CursorMotion-<version>.dmg` GitHub Releases 发布链路。 |
| 2026-04-19 | 权限浮窗细节收口 | `Allow` 后的引导浮窗动效更连贯，且在系统设置窗口稳定后能自动落到正确位置，不需要用户手动点一下再归位。 | 发布 `0.1.12`，补齐权限 panel 的 source-to-target 入场动画、返回按钮，以及动画结束后的持续 re-anchor，修复 release workflow 因 npm 版本仍停在 `0.1.11` 而发布失败的问题。 |
| 2026-04-18 | 权限浮窗与文档入口 | 第一次冷启动系统设置时权限浮窗能直接出现，仓库根目录也重新补回中文文档入口。 | 发布 `0.1.11`，修复首次 `Allow` 冷启动 `System Settings` 时辅助浮窗需要切窗后才显示的时序问题，并新增根目录 `README.zh-CN.md` 承载中文说明。 |
| 2026-04-18 | 权限身份与 onboarding | npm 安装后的权限身份更稳定，已授权用户不会被重复弹窗打扰。 | 发布 `0.1.10`，统一 bundle identifier 为 `com.ifuryst.opencomputeruse`，让权限检测兼容路径型 TCC 记录并优先认 npm 全局安装后的 app；同时让 `doctor` / 默认启动在权限齐全时不再弹出 onboarding，完成授权后自动关窗。 |
| 2026-04-17 | 发布稳定性 | release workflow 不再因为 Xcode 26 的 CoreFoundation 类型检查而在构建阶段提前失败。 | 发布 `0.1.9`，修复权限引导窗口里 `AXUIElement` 属性读取在 `macos-26` / Xcode 26.2 下的编译错误，恢复 npm release artifact 构建链路。 |
| 2026-04-17 | 权限引导与安装 | 权限授权浮窗在 `Allow` 后不再掉到屏幕底部，且仓库继续提供稳定的一键安装/发布版本。 | 发布 `0.1.8`，收口 `System Settings` 跟随 panel 的定位修复，并同步更新插件、CLI、smoke/test 与发布文档中的版本号。 |
| 2026-04-08 | 模板仓库 | 提供了一套可直接用于新项目启动的 Agent-first 基础模板。 | 补齐了 AGENTS 入口、execution plan、history、release note、CI/CD 和供应链安全骨架。 |
| 2026-04-17 | 开源 computer-use | 提供了一版可本地运行、可回归验证的 Swift `computer-use` MCP server。 | 新增 Swift package、9 个 tools、fixture app、smoke suite、`doctor`/`snapshot` 诊断入口和对应架构文档。 |
