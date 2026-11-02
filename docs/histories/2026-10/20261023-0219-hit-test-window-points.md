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

### 2026-10-31 maintainer review

- Merged current main (`a7fdec1`), retaining both sides of the release-note conflict and the original contributor commit.
- Kept the production fix; added opt-in debug logging of window/screen hit-test points and AX result codes.
- Added `scripts/tests/macos-hit-test-smoke.mjs` and its real AppKit receiver. This uses native MCP and ordinary AX APIs, not the synthetic fixture bridge. Run with a normally signed, admitted OCU executable on an unlocked Retina desktop with Accessibility/Screen Recording permissions.
- Verified 600×432-point window with 1200×864 (2×) and 300×216 (0.5×) screenshots: indexed fallback hits the expected screen point and never presses the unrelated button; screenshot-coordinate auto clicks reach the button, with correct hit-test coordinates. AX-only indexed fallback succeeds, while coordinate clicks without an image fail. Explicit accessibility clicks are observed by the receiver. Foreground PID and physical pointer remain unchanged during actions.
- Negative control: changing only the conversion back to `screenshotToGlobalPoint` makes the same live regression fail: expected (490,627), actual (305,498.5). Restored the fix afterward.
- Limits: one physical Retina display; this tests AX hit locations and real button activation, not general background mouse delivery to actionless custom views. The separate descendant-selection issue remains in #127.
- Full Swift suite: 399 tests, 9 skipped, no failures. Documentation checks passed.

### Follow-up main synchronization

- Merged main `21a33a4` after #139 landed. Resolved only the release-note insertion conflict, preserving both feature entries. Hit-test implementation and its regression tests are unchanged from the previously tested head.
- Documentation and whitespace checks passed; no repeat desktop run was needed for the documentation-only resolution.
