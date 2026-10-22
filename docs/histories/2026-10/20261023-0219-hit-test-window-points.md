## [2026-10-23 02:19] | Task: 修复 macOS 点击命中测试的坐标空间

### Execution Context

- Agent ID: Claude Code subagent（Agent tool 派发）
- Base Model: Claude Opus 5.5
- Runtime: Claude Code CLI

### User Query

> 修复 `hitTestElement` 把窗口点当成截图像素换算的问题，并用最小的回归检查证明修复前后行为差异。

### Changes Overview

- `hitTestElement(at:in:)` 改用 `windowPointToGlobalPoint` 换算，补一行注释说明入参是窗口点（`ElementRecord.localFrame` 的坐标空间）。
- 两处调用方都传窗口点：坐标点击的 `clickCandidates`（已经由截图像素换算成窗口点）和 element_index 点击的就近命中回退（`clickActionPoints` 来自 `clickFrame`）。
- 坐标拖拽仍走 `screenshotToGlobalPoint`，它的入参确实是截图像素，不受影响。

### Design Intent

截图与窗口不是 1:1 时（Retina 缩放、`maxLongEdgePixels` 上限，几乎总是如此），命中测试会被再除一次缩放比例，探测到错误位置。实测在 2x 屏幕上点击表格行时，命中测试落到上方的列表头并对它执行了 AXPress。另外，`include_screenshot:false` 的 element_index 点击在这条回退里会误报 "coordinate input requires a delivered screenshot"，尽管调用方根本没有给坐标。只改共享的换算函数即可同时修好两个调用方。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `docs/releases/feature-release-notes.md`

### Validation

- 用一个不激活、位于所有窗口之后的 AppKit 探针（无动作的表格行 + 列表头）在进程内运行 CLI（禁用 app agent 代理与软件光标），打开点击决策调试日志：
  - 修复前：`click element_index`（行，窗口点 y=104..128）的就近命中把窗口点 (125,116) 当作像素换算成全局 (122,608)，命中列表头 AXButton（y=42）并执行 AXPress。
  - 修复后：同一窗口点换算为全局 (185,666)，命中该行自己的 AXStaticText（y=108），不再按下列表头。
  - 修复前 `get_app_state include_screenshot:false` 后的 element_index 点击报截图缺失错误；修复后不再报错。
- 坐标点击路径用同一个函数，命中测试同样落到正确的行文字上；但在该探针里快照中的窗口记录会先处理点击，因此该路径的最终结果在探针中看不出差异。
- `swift test` 全量通过。
