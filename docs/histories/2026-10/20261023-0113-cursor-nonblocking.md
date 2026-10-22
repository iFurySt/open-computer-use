## [2026-10-23 01:13] | Task: 软件光标动画不再阻塞 tool call

### Execution Context

- Agent ID: `Claude Code`
- Base Model: Claude Opus 5.5
- Runtime: Claude Code CLI / macOS arm64

### User Query

> `VisualCursorSupport.performOnMain` 用 `DispatchQueue.main.sync`，每次 click 都要等光标滑动和点击反馈播完（约 1.6 秒）。在当前 main（含 #95 窗口跟随）上改为不阻塞：动作按序排队播放，连续动作自适应加速，加速后仍落在目标点；不引入时长缩放参数，不改光标外观，不回退窗口跟随。确认截图是否会带上滑动中的光标，并给出前后测量。

### Changes Overview

- `performOnMain` 从工具线程调用时改为 `DispatchQueue.main.async`，tool call 不再等待动画。主队列按投递顺序播放：一个 block 在动画中 pump run loop 时，主队列不会开始下一个 block（已用独立程序和单测确认），因此不需要额外的待播队列。主线程调用（一次性 CLI）仍内联播放。turn-ended reset 走同一路径，排在已投递的动作之后。
- 新增纯函数 `adaptiveCursorTempo`：按距上一个动作结束的间隔缩放 move / pulse 时长，连续动作逐次乘 0.6 直到下限（`OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR`，默认 0.15，设为 1 关闭），空闲 2 秒恢复原速。直接作用于现有时长，没有引入 duration scale。
- visual dynamics 弹簧改用随节奏加速的时钟（`dynamicsTime` / `paceDynamics`）。所有创建或推进 dynamics state 的位置都换到这条时钟，包括 #95 新增的 `reanchorIfWindowMoved`，避免时间域混用。
- 窗口追踪注册（`makeCursorWindowAnchor`、`visualCursorTarget(for:snapshot:)`）也投递到同一队列。否则 tool 线程会在前一个排队动作播放前注册新窗口，而前一个无锚点动作播放时的 `forgetAll()` 会清掉它，导致后一个动作不再跟随窗口。
- 新增 opt-in `CursorAnimationLatencyLiveTests`（`OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1`）：10 次连续 click 的调用方阻塞时间、每次动画时长、追上时间、落点误差，以及窗口截图不含 overlay 的检查。新增非 live 单测：节奏函数、主队列顺序与不阻塞、注册与排队动作同序。
- 同步架构说明、skill 使用说明和功能发布记录。

### Design Intent

光标只是给人看的，不应该让 tool call 等它。排队而不丢弃，每个动作仍按原路径播放；积压时间隔为 0，由自适应节奏追上。加速只改时间轴不改路径，所以弹簧也要放到同一条时间轴上，否则越快越偏。窗口截图走 `SLSHWCaptureWindowList` / `SCContentFilter(desktopIndependentWindow:)`，只抓目标窗口，overlay 是独立窗口，不会出现在截图里，无需额外处理。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CursorAnimationLatencyLiveTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CursorWindowAnchorTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`
- `skills/open-computer-use/references/usage.md`

### Validation

- 同一份 live 测试先在 origin/main 上运行，再在本分支运行（单屏，默认参数）：
  - 调用方每次 click 阻塞：1604.9 ms（最大 1613.3）→ 0.00 ms（最大 0.01）。
  - 10 次 click 光标全部播完：16050 ms → 5111 ms；每次动画 1624 → 976 → 590 → 363 → 253 ms 后稳定在下限，空闲 2.2 秒后回到 1610 ms。
  - pulse 开始时的落点误差：最大 0.3 pt → 0.2 pt。临时去掉加速时钟（弹簧走墙上时钟）对照，连续 click 落点偏差最大 11.6 pt。
- 窗口截图检查在 origin/main 和本分支都通过：overlay 位于测试窗口中心时，`SLSHWCaptureWindowList` 截图与无 overlay 时逐字节相同。
- 注册顺序单测在改回立即注册时失败，排队注册时通过。
- `swift test`：387 项，9 项跳过（opt-in live 测试），0 失败；`CursorWindowFollowTests` 8 项全部实际运行并通过，包括真实 AX 窗口跟随和 service click 集成。
- 只在单块显示器上测量，未做双屏拖动。
