## [2026-10-23 02:18] | Task: Add settle_ms to get_app_state

### Execution Context

- Agent ID: Claude Code 子 Agent（运行时未暴露 ID）
- Base Model: Claude Opus 5.5（`claude-opus-5-5`）
- Runtime: Claude Code（Claude Agent SDK），macOS 本机

### User Query

Agent 在动作之后读取状态前只能猜一个 sleep。把 fork 里“轮询窗口指纹直到不再变化”的等待移植到上游，用最小的接口面（优先给 `get_app_state` 加可选参数而不是新工具），测出每次轮询的成本，并判断动作回读的固定停顿是否应复用它。

### Changes Overview

**Scope:** macOS `OpenComputerUseKit`、Linux / Windows Go runtime 的参数校验、Node REPL、文档。

- `get_app_state` 新增 `settle_ms`：读取前约每 100 ms 给目标窗口算一次 AX 指纹，连续 `settle_ms`（上限 2000）不变即照常读取；最长等待 5 秒。结果在状态文本之后、截图之前附一行，说明是否稳定以及等了多久。
- 指纹复用 `query` 的有界 BFS（同样的可见性裁剪、大容器只走可见子节点、2 秒协作截止），新增只做指纹的遍历模式：哈希每个访问节点的角色、标题、描述、值和窗口内相对布局，不生成记录、不读动作。节点上限取本次 `get_app_state` 的 `max_tree_nodes`。
- 稳定判断是可注入时钟与 sleep 的纯函数 `waitForStableDigest`，用合成指纹覆盖静止、加载后停止、单次抖动、永不停止与等待上限小于静止期等情况。
- 等待前检查会话租约；找不到可绑定的窗口时跳过等待并注明，照常读取。
- 动作回读保留固定的短暂停顿，不复用这项等待。
- Linux / Windows 收到 `settle_ms` 时明确报不支持。Node REPL 的状态读取接受 `settleMs`。
- 更新 schema 测试、参数校验测试，以及 SKILL、usage、js-repl、ARCHITECTURE 和功能发布记录。

### Design Intent

等待放在 `get_app_state` 的一个可选参数上，因为它本来就是“动作之后读状态”的那一步，调用方已经在那里决定何时读取；新工具只会多一次往返。指纹选 AX 而不是截图：光标闪烁、视频和 CSS 动画会让像素永远在变，而加载、弹出 sheet、列表滚动都会体现在角色、文本、值或布局上。上限固定为 5 秒，与 `query` 固定 2 秒截止的做法一致，避免持续变化的窗口拖慢每次读取。动作回读不复用：那会改变每个动作的延迟，动画中的窗口每次动作都可能等满上限，而需要等待的调用方可以在下一次读取时明确提出。

### Validation

- `swift test`（共享 GUI 锁下运行完整套件）：384 tests，7 skipped，0 failures。
- 新增单测：稳定判断（合成指纹与假时钟）、`settle_ms` 非法值（0、-1、1.5、true、"300"）、schema。
- Node REPL：44 tests passed；Linux / Windows 新增用例通过，两平台 `go vet` 通过。
- 真机（不激活、不抢焦点的探针 app，`include_screenshot: false`，`settle_ms: 300`）：
  - 静止窗口：Settled，等待 367 ms，4 次指纹，单次中位 1.4 ms。
  - 标签每 50 ms 变化、持续 2 秒：Settled，等待 2343 ms，读到停止后的文本。
  - WKWebView 400 行、每 50 ms 插入一行、持续 2 秒：Settled，等待 2127 ms，读到加载完成后的页面；单次指纹中位 21.6 ms，最大 25.8 ms。
  - 永不停止的标签：Not settled，4998 ms 时放弃（整次调用 5047 ms），返回当时的状态。
  - 后台只读测量：TextEdit 单次指纹中位 18.2 ms（最大 30.8 ms），Finder 列表窗口中位 34.6 ms（最大 39.0 ms；前一轮最大 51.1 ms）。
  - 不带 `settle_ms` 的同一读取：97 ms，行为不变。前台 app 未被改动，探针已退出。
- `make check-docs`、`git diff --check` 通过。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/TargetedQuery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/TargetedQuerySafetyTests.swift`
- `apps/OpenComputerUseLinux/main.go`、`apps/OpenComputerUseLinux/main_test.go`
- `apps/OpenComputerUseWindows/main.go`、`apps/OpenComputerUseWindows/main_test.go`
- `scripts/node-repl/open-computer-use-repl.mjs`、`scripts/node-repl/open-computer-use-repl.test.mjs`
- `skills/open-computer-use/SKILL.md`、`skills/open-computer-use/references/usage.md`
- `docs/references/js-repl.md`、`docs/ARCHITECTURE.md`、`docs/releases/feature-release-notes.md`
