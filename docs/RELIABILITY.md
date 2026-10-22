# 稳定性与可运维性

## 当前最低验证线

- 构建：`swift build`
- 单元测试：`swift test`
- JS REPL 与 CLI：`node --test scripts/node-repl/*.test.mjs`
- 端到端 smoke：`./scripts/run-tool-smoke-tests.sh`
- macOS SkyLight 实机回归：`OPEN_COMPUTER_USE_RUN_SKY_CLICK_LIVE_TEST=1 swift test --filter SkyClickLiveTests`
- macOS SkyLight 后台键盘实机回归：`OPEN_COMPUTER_USE_RUN_SKY_KEY_LIVE_TEST=1 swift test --filter SkyKeyboardLiveTests`
- macOS 被遮挡窗口 keep-alive 实机回归：`OPEN_COMPUTER_USE_RUN_OCCLUSION_LIVE_TEST=1 swift test --filter OcclusionKeepAliveLiveTests`
- macOS 多 app 扫描（对运行中的每个 GUI app 做 read-only snapshot，并在空白文本框里输入再删除一个标记；会向真实 app 输入，只在无人使用时跑）：`OPEN_COMPUTER_USE_RUN_APP_MATRIX=1 swift test --filter AppMatrixLiveTests`；加 `OPEN_COMPUTER_USE_APP_MATRIX_PARK=1` 会把每个非全屏窗口停靠到 agent display 上做同样的事再移回原位。
- macOS 后台输入基准（25 轮 `sky_click` + `sky_key`，输出成功数与 p50 / p95 / max）：`OPEN_COMPUTER_USE_RUN_BACKGROUND_BENCH=1 OPEN_COMPUTER_USE_BENCH_CYCLES=25 swift test --filter BackgroundInputBenchmarkLiveTests`
- 基准结果与复现命令汇总在 `docs/references/background-input-benchmarks.md`。
- 输入默认值以跨版本可靠性优先：普通 `auto` 的 type chunk / press-key settle 保持 20 / 100 ms，`sky_key` 的 key-window / release settle 为 10 / 10 ms；六个 timing knob 均可通过对应 `OPEN_COMPUTER_USE_*` 环境变量显式覆盖。
- 逐阶段耗时：任何命令前加 `OPEN_COMPUTER_USE_DEBUG_TIMING=1`，stderr 输出 `[open-computer-use] timing <阶段> <ms>ms`（`sky_key.*`、`sky_click.total`、`snapshot.window_capture`、`snapshot.tree_walk`、`agent_display.*`）。
- 跑实机回归时不要在这台 Mac 上打字或点鼠标：测试会短暂把目标窗口放到前台，用户的按键会落进去，前台 fixture 也会因用户操作失去 active。
- macOS agent display 实机回归（会短暂创建并销毁一块 virtual display）：`OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST=1 swift test --filter AgentDisplayLiveTests`
- macOS agent display 开销（Chrome 帧率与 CPU、WindowServer CPU、点击到截图延迟；覆盖、停靠、恢复三段）：`OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_COST=1 swift test --filter AgentDisplayLiveTests/testParkedWindowCost`，加 `OPEN_COMPUTER_USE_AGENT_DISPLAY_REFRESH_HZ=60` 对比旧刷新率。
- macOS 其他 Desktop 实机回归（需要第二个 Desktop，测试会短暂切换 Space 启动目标）：`OPEN_COMPUTER_USE_RUN_CROSS_SPACE_LIVE_TEST=1 swift test --filter CrossSpaceLiveTests`
- Linux runtime：`(cd apps/OpenComputerUseLinux && go test ./...)`、`./scripts/build-open-computer-use-linux.sh --arch arm64`
- Linux 隐藏控件实测：`bash scripts/run-linux-read-back-smoke.sh /path/to/linux/open-computer-use --hidden-checks`，在私有 D-Bus / Xvfb 中验证真实 GTK 隐藏状态、属性读取、索引及页面切换；依赖与范围见 [测试说明](linux-hidden-details.md)。
- Linux 按需观察实测：`bash scripts/run-linux-read-back-smoke.sh /path/to/linux/open-computer-use --observation-checks`，验证真实 GTK 采集通道、native MCP / Worker JS 输出、旧索引拒绝与恢复；另外需要 Node.js，见 [测试说明](selective-observation.md)。
- Windows runtime：`(cd apps/OpenComputerUseWindows && go test ./...)`、`./scripts/build-open-computer-use-windows.sh --arch amd64`；截图相关变更还要在 Windows 交互桌面验证正常窗口有 image、1x1/minimized/cloaked 窗口无 image。
- Windows 输入实测：`pwsh -File scripts/tests/windows-input-smoke.ps1 -NativePath /path/to/open-computer-use.exe`，验证真实默认滚动回退、四向物理滚轮、截图坐标点击、拖拽、组合键、移动 / 遮挡拒绝及 Worker JS；记录实际 DPI，见 [说明](windows-input.md)。
- Windows 观察实测：`pwsh -File scripts/tests/windows-observation-smoke.ps1 -NativePath /path/to/open-computer-use.exe`，使用独立 WPF 窗口走真实 UIA / native MCP，验证采集开关、索引与截图边界；专用 PR 工作流见 [CI 说明](CICD.md)。
- 本地诊断：
  - `open-computer-use doctor`
  - `open-computer-use snapshot <app>`

## 已知关键依赖

- macOS 上必须给 `Open Computer Use.app` 授权 `Accessibility` 与 `Screen Recording`；终端本身不应该再是必需授权对象。
- Codex plugin 的 code-first surface 需要可执行的 `node`。REPL adapter 会为 native MCP 保留独立 child lifecycle，JavaScript kernel 则放在 Worker 中；脚本超时会丢弃该 Worker 的全部 bindings，并由下一次调用使用新的 kernel。
- npm CLI 本身也由 Node 启动。`ocu js` 只在一次执行期间保留 Worker/native MCP child；`ocu repl` 在当前 terminal session 内保留它们；`ocu mcp` 则跟随 stdio connection。macOS 的隐藏 app agent 是独立的权限身份，可能在这些前台命令退出后继续驻留。
- `ocu --help` 始终展示 `js` / `repl`；`ocu capabilities --json` 可在不启动 native MCP 的情况下检查 Node、adapter、kernel 和 native artifact。当前 npm shebang 仍要求 shell 能从 PATH 启动 Node，所以“完全无 Node”必须在更外层用 native bootstrap 解决。
- macOS `click_method=sky_click` 额外依赖 SkyLight / ApplicationServices 私有符号 `SLEventPostToPid`、`SLEventSetIntegerValueField`、`CGEventSetWindowLocation`、`SLPSPostEventRecordTo` 和 `GetProcessForPID`。截图主路径依赖可选的 `SLSHWCaptureWindowList`，窗口绑定依赖可选的 `_AXUIElementGetWindow`，缺失时分别退回 ScreenCaptureKit 与标题启发式。运行时会动态探测并 fail closed，但 macOS 更新、签名方式或目标 app 输入策略变化仍可能让后台投递失效。受控实机回归除 DOM、前台 PID、鼠标和 z-order 外，还必须验证前台 AppKit active、key window、first responder 以及 resign/key-loss 计数。`key_method=sky_key` 复用同一组符号，实机回归还要确认被遮挡 Chrome 的输入框收到文字、`cmd+a` 菜单快捷键生效，以及投递结束后 Chrome 页面重新 blur。
- agent display 依赖私有 `CGVirtualDisplay` 类、KVC key 与 selector。shim 会捕获 Objective-C exception 并把创建失败收敛成 capability unavailable；不允许私有 API 漂移直接终止 host 进程。显式 `restore` 按 app PID 恢复该 runtime 停放的全部窗口；turn-ended 和 MCP/REPL connection 关闭也会释放 occlusion keep-alive、恢复窗口并销毁空闲 display。
- smoke suite 依赖本地 GUI session，不能把它当成无头环境命令。
- 普通 app 的 `get_app_state` 结果依赖 AX tree 和窗口截图，复杂 app 上输出会有差异；Electron/WebView app 的 AX tree 通常很深，当前会压缩空 wrapper 并放宽遍历深度，以优先保留可操作文本、按钮和输入框。
- Linux runtime 依赖已登录桌面用户 session；缺少 `XDG_RUNTIME_DIR`、`DBUS_SESSION_BUS_ADDRESS` 或 display 环境时，会尝试从 `/run/user/<uid>` 和常见桌面进程自动发现当前用户的 session env。纯 SSH tty 如果找不到桌面 session 仍不能直接访问 AT-SPI GUI tree。
- GNOME Wayland 截图可能被 compositor 限制，当前 Linux bridge 会把黑图视为无效截图并省略 image block。

## 当前故障排查顺序

1. 先跑 `open-computer-use doctor`，确认权限状态；如果缺权限，命令会通过 `.app` app agent 拉起权限 onboarding 窗口，已全部授权则只打印状态并退出。
2. 用 `open-computer-use list-apps` 确认目标 app 是否被发现。
3. 用 `open-computer-use snapshot <app>` 看是 transport 问题还是 snapshot / action 问题。
4. 如果 `sky_key` 输入没有落到目标：先确认目标不是隐藏 app、窗口仍属于同一 PID；Chromium 目标可以在页面里观察 `document.hasFocus()`，投递期间应为 true。跑实机回归时不要同时在其他窗口打字，否则前台 fixture 会因为用户自己的操作失去 active。
5. 如果被遮挡或其他 Space 的 Chromium / Electron 窗口 tree 里没有网页内容，看 tree 末尾是否有 “window is covered” 说明：说明 agent 第一次看到它时它已经被遮挡。让窗口露出一次再 `get_app_state`，之后再遮挡也会保留内容；或者在同一 session 里显式调用 `get_app_state` 并传 `window_placement=agent_display` 把窗口停靠到 agent 显示器，用完 `restore`。若 session 已结束，runtime 会自动恢复，不需要另开连接补 `restore`。
6. 如果只有 `sky_click` 失败，先重新执行 `get_app_state`，确认窗口仍属于同一进程且 app 未被隐藏；错误里出现 `missing SkyLight symbols` 时不要改用隐式 fallback，应按当前 macOS 版本重新验证私有 SPI。被遮挡的 Chromium 页面仍无效果时，再用受控页面区分 renderer 策略变化与坐标/window-local 映射问题。
7. 如果只想验证仓库基线，直接跑 fixture + smoke，不要先在复杂第三方 app 上排查。
8. 排查 Linux runtime 时，先确认目标命令是否由桌面用户运行，再用 `open-computer-use call list_apps` 和 `open-computer-use snapshot <app>` 区分 session/env 问题与 AT-SPI tree/action 问题。如果是 Codex MCP，重新执行 `open-computer-use install-codex-mcp` 后重启 Codex，确认配置仍是 `open-computer-use mcp`。
9. Windows snapshot 返回 accessibility tree 但没有 image 时，先确认窗口可见、未最小化、未 cloaked、位于 virtual screen 内且不是退化小窗口；无 image 时不要调用 coordinate click / drag，优先使用 `element_index`。
10. 排查 `ocu js` / `ocu repl` 时先执行 `ocu capabilities --json`。缺少 adapter、kernel 或 native artifact 时重新安装 npm 包；若 shell 报 `node: command not found`，说明 npm launcher 本身尚未启动，需要先安装 Node 或等待未来 native bootstrap 方案。

## 后续补强方向

- 增加结构化日志和失败原因分类。
- 继续补充 screenshot capture / AX traversal 的失败上下文和普通 app 回归样本。
- 增加普通 app 回归样本，而不是只覆盖 fixture。

CI/CD 流程结构和 release 自动化的默认方案，统一写在 `docs/CICD.md`。

## macOS Locked Use 预检

- `ocu locked-use status --json`：只读检查当前会话 / runtime 权限 / 安装组件；普通 enable 安装并请求权限，status 检查签名、客户端批准与认证规则；开发诊断 profile 不属于普通开启流程。
- `swift test --filter LockedUseTests`：许可、租约、超时、显示器变化、本地接管和重锁确认策略回归。
- `./scripts/build-locked-use-plugin.sh`：构建 deny-only ABI probe 并在普通进程内测试；通过不代表 SecurityAgent 加载成功。
- `./scripts/build-locked-use-guardian.sh`：构建独立 Guardian / child watchdog；`--diagnose` 与签名构建后的 `--peer-self-test` 为非锁屏诊断。先运行 `python3 scripts/run-locked-use-rehearsal.py --shield-preview` 观察 15 秒倒计时与所有物理屏幕；用户准备好后才运行 `--confirm-lock-test`，验证窗口 AX / SCK 与重锁结果；人工 GUI 测试不进入自动 CI。`python3 scripts/tests/locked-use-rehearsal.test.py` 不启动 GUI / 锁屏，回归 controller 的恢复顺序和 preview 不锁屏边界。
- 系统插件加载实验和后续真实锁屏测试是独立的人工门槛，不进入常规 CI / smoke，也不在日常账户自动运行。步骤和恢复路径见 [Locked Use](locked-use.md)。

- Root 的认证策略读取使用独立队列；策略待定 / 过期 / 失败时停止新许可，协调队列继续处理恢复。独立 agent deadline 限制准备 / 停止时间，仍须验证真正撤罩和正常手动解锁的耗时。
- `python3 scripts/run-locked-use-native-validation.py --confirm-recovery-test` 是验证 profile 的人工故障收束入口，不签发解锁许可。必须同时证明两个保护确曾就绪、原会话锁定、动作排空与双方释放 ACK，才报告通过。

- `python3 scripts/run-locked-use-smoke.py --app <signed-app> --guardian <guardian-binary> --fixture <demo-app> --confirm-lock-test` 通过正常 MCP 读取 / 点击 / 截图验证普通 enable 的闭环，不使用测试解锁 RPC 或 Keychain。成功后保留 Counter 窗口，失败先结束租约并等待双方保护释放。
- 首次原生连接握手的响应预算为 8 秒，冷签名校验由独立的有界工作队列完成；动作、保护和插件 RPC 仍为 2 秒。策略观察过期停止当前工作并等待新观察，不永久禁用安装；确认认证策略变化才永久禁用当前服务 epoch。

Locked Use Broker uses a one-second timer only when idle or awaiting manual unlock with both guards fully released. Any active / incomplete recovery state retains the 100 ms watchdog cadence; incoming state transitions restore it immediately. Policy observations remain once per second with the existing two-second freshness gate. This reduces idle wakeups without extending guard / permit deadlines.

Known-peer heartbeat/message revalidation on macOS 14.4+ uses kernel code-hash requirements instead of repeated certificate/disk assessment on the control queue. Forwarded SCM_RIGHTS clients also enter through the signature worker pool with an eight-second deadline; cancellation releases only the borrowed descriptor after in-flight verification finishes, preventing descriptor reuse races without shutting down the caller’s live transport.

Installer removal leaves StagedPlugins to authd. Installation waits only for an existing mismatched cache to disappear or match the expected signature hash, for at most 15 seconds. The smoke controller retains its verified demo after relock/dual release even if manual-unlock observation times out; that timeout remains a failed manual check.
