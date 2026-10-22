## [2026-10-23 02:10] | Task: Add set-of-marks and zoom to macOS get_app_state

### 🤖 Execution Context
* **Agent ID**: `Claude Code subagent`
* **Base Model**: `Claude Opus 5.5 (claude-opus-5-5)`
* **Runtime**: `Claude Code CLI, macOS local git worktree`

### 📥 User Query
> 把 fork 中的 set-of-marks 和窗口局部放大移植到上游：作为 `get_app_state` 的可选参数，编号沿用 click / set_value 已使用的 element_index，不新增索引空间；zoom 为可选裁剪。核对与图片配置（format / maxLongEdgePixels）及 `include_screenshot:false` 的交互，在真实窗口上测量额外开销，补单元测试和后台实测。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`apps/OpenComputerUseLinux`、`apps/OpenComputerUseWindows`、`scripts/node-repl`、文档

**Key Actions:**
- **marks**：`get_app_state` 新增 `marks`（默认 false）。树遍历后选出启用且可操作的元素（press / pick / confirm / open / increment / decrement 动作、文本输入、行），在截图上画框并标注其 `element_index`；树文本只多一行说明。需要 `include_ax` 与 `include_screenshot` 同时开启，否则拒绝。
- **zoom**：新增 `zoom: {x, y, width, height}`（窗口比例），按比例裁剪采集图、保留采集分辨率后再走既有编码；快照记录缩放区域，`click` / `drag` 的截图坐标按放大图换算回窗口坐标。需要 `include_screenshot`；越界、非数字或零尺寸在解析应用前拒绝。
- **图片配置**：标记在缩放之后、编码之前按最终像素绘制，标签大小与图片尺寸无关；格式、`maxLongEdgePixels`、`scaleDownAfterMaxSize`、`discardBelowPixelCount` 照常生效，标记图与未标记图尺寸一致，坐标换算不变。标记图只编码一次。
- **其他平台与 JS**：Linux / Windows 对 `marks: true` 或 `zoom` 明确返回 not supported；JS REPL 透传 `marks`（严格布尔）与 `zoom`。
- **测试**：新增 `SetOfMarksTests`（选元素、标签位置互不重叠、上下翻转方向、标记后尺寸不变、缩放区域与坐标换算、参数校验、dispatcher 解析、schema），Node REPL 转发测试，Linux / Windows Go 拒绝测试。

### 🧠 Design Intent (Why)
沿用 tree 已打印的 `element_index`，视觉模型读到的编号可直接用于现有元素动作，不需要第二套编号和映射状态。选项放在 `get_app_state` 而不是新工具，与 `include_ax` / `include_screenshot` 一致。在最终尺寸上绘制标记，避免缩放把细框和数字缩糊，也让持久化图片配置对标记图同样生效。zoom 记录在快照的观察选项里，坐标换算只在一个纯函数中扩展。

实测（自建不激活、不可成为 key 的 AppKit 窗口，置于其他窗口之后，PNG 默认配置）：标记图与原图同为 1280×898，PNG 165 KB → 179 KB；15 轮交替读取的 `get_app_state` 中位数 61.0 ms → 62.2 ms，`snapshot.marks`（裁剪 + 绘制 + 编码）中位数 15.8 ms，其中编码本来就要做。JPEG 800 像素配置下 43 KB → 94 KB，细框使 JPEG 体积明显变大。zoom 上半右四分之一得到 900×632 原分辨率图，按放大图像素坐标点击 Reload 命中，探针应用始终未激活，前台应用不变。

已知限制：滚动区域里被裁掉的部分可见行仍按其 frame 标注（表格最后一行可能落在空白处）；没有按祖先滚动区域裁剪。

### ✅ Validation
- `swift test`：390 tests，7 skipped，0 failures（main 为 382 / 7 / 0）。
- `node --test scripts/node-repl/*.test.mjs scripts/tests/*.test.mjs`：50 passed。
- Windows `go test ./...` 通过；Linux 新增拒绝测试通过，其余 6 个需要 Linux python3 runtime 的测试在 macOS 上与 main 一样失败；两平台 `go vet` 通过。
- `make check-docs`、`git diff --check` 通过。
- 后台实测见上，未在 Linux / Windows 桌面运行。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SetOfMarks.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SnapshotObservationOptions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SetOfMarksTests.swift`
- `apps/OpenComputerUseLinux/main.go`
- `apps/OpenComputerUseLinux/main_test.go`
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/main_test.go`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `scripts/node-repl/open-computer-use-repl.test.mjs`
- `skills/open-computer-use/SKILL.md`
- `skills/open-computer-use/references/usage.md`
- `docs/references/js-repl.md`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`
