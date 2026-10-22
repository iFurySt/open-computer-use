## [2026-10-23 01:19] | Task: 修复 agent display 的显示器排列与被 macOS 移走的窗口

### Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS 27 arm64`

### User Query
> 把 fork 在 #65 合入后发现的 agent display 问题整理成上游 PR：创建 agent 显示器时 macOS 把用户的其他显示器挤开，以及 macOS 把窗口移到新建的 agent 显示器上。只移植上游代码路径上真实存在的问题，单屏机器不受影响。

### Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`docs/references`、`docs/releases`

**Key Actions:**
- **[显示器排列]**: macOS 把新显示器放在主屏旁边，并会把用户的其他显示器挤开（fork 在 2026-10-16 观察到：内建屏、agent 显示器、被推到右边的外接屏），鼠标在用户两块显示器之间移动时会穿过看不见的 agent 显示器。`ensureDisplay` 在显示器就绪后比较用户显示器创建前后的 bounds：有变化就按原位置放回（`kCGConfigureForSession`），agent 显示器放到最右侧显示器的右边、与其顶边对齐；没有变化时不调用任何显示器配置 API，所以单屏机器行为不变。镜像中的显示器不设 origin，避免把它移出镜像组。
- **[被 macOS 移来的窗口]**: shim 给 agent 显示器固定的 vendor / product / serial，macOS 把它当成同一块显示器。上一块 agent 显示器消失时还在上面的窗口（进程被强杀、来不及 restore），在下一块 agent 显示器出现时会被 macOS 移回去，停靠期间从用户屏幕上消失。`ensureDisplay` 记录创建前的屏上窗口，就绪后把“创建前在用户显示器上、现在在 agent 显示器上”的未停靠窗口用 AX 移回原位置。
- **[纯函数与测试]**: 判定逻辑抽成 `agentDisplayOrigin(displaysBefore:displaysNow:)` 和 `windowsMovedOntoAgentDisplay(_:userDisplays:before:now:)`，新增两项单元测试覆盖被挤开、左侧外接屏、未移动 / 单屏、空列表，以及被移来、未移动、原本就伸进该区域、已关闭和 Space 切换途中读到的偏移 frame。
- **[文档]**: 更新 agent display 参考文档里的排列、副作用与未解决项，补功能发布记录。

### Design Intent (Why)
agent display 应该只增加一块用户看不见的屏幕，不改变用户自己的显示器排列，也不把用户的窗口藏起来。

fork 后续提交里只移植上游代码路径上存在的部分。上游的 teardown 已经做到停靠窗口回到原位：`restore` 移回 AX 位置并以容差确认，确认失败保留记录和显示器以便重试；turn-ended、连接关闭和进程退出都会 `restoreAll`。fork 中依赖 `prepare_app`、关闭 agent 打开的窗口、用户自己放到 agent 显示器上的窗口、按 pid 设置 serial、焦点交还等改动对应上游没有的功能或另外的问题，这里不带入。

只在用户显示器确实被移动时才重新配置，是为了让单屏和 macOS 本来就没挤开显示器的情况完全不调用显示器配置 API。`CGCompleteDisplayConfiguration` 返回后配置即失效，所以失败时不再调用 `CGCancelDisplayConfiguration`。

窗口移回只信任落在用户显示器上的创建前 frame：实测中 Space 切换途中读到的 frame 整体偏移一个屏宽，移回那里会把窗口放到屏幕外；这种情况下保持上游原有行为（显示器销毁时 macOS 会把窗口送回）。

### Validation
- 本机只有一块内建屏（`CGGetActiveDisplayList`：`0,0 1512x982`），多显示器挤开的问题无法实机复现，排列逻辑由单元测试覆盖。
- 被移来的窗口在单屏上实机复现（GUI 锁内，用自建的不激活探针窗口）：进程 A 停靠窗口 P 后 `_exit`，P 回到 `(300,268)`；进程 B 停靠另一个窗口时，修复前 P 被 macOS 移到 agent 显示器 `(1552,40)` 并一直留在那里；修复后 P 被移回 `(300,268)`，同一身份的显示器再次创建时 macOS 不再移动 P。
- `OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST=1 swift test --filter AgentDisplayLiveTests` 通过；显示器排列在测试前、停靠中（agent 显示器 `1512,0 1920x1080`）、测试后一致，内建屏始终是 `0,0 1512x982`，前台 app 不变。
- `swift test`：384 项测试，7 项跳过，0 失败。

### Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AgentDisplay.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/references/macos-window-visibility-and-spaces.md`
- `docs/releases/feature-release-notes.md`
