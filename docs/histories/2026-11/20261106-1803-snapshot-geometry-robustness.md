## [2026-11-06 18:03] | Task: 出屏窗口整窗截图与 NaN frame 不再崩溃

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 计算器切到科学型后窗口部分出屏，截图只有屏内部分，坐标全部偏移；Contacts 新建卡片编辑态下 `get_app_state` 让进程直接 trap。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[WindowCaptureGeometry]**：窗口完整落在某块显示器内才用硬件截图，否则走 ScreenCaptureKit 整窗捕获；像素尺寸必须与窗口 bounds 等比，否则不给图。SCK 的尺寸以 CG bounds 为准。
- **[NaN frame]**：`resolveLocalFrame` 把非有限的 AXPosition / AXSize 当作无几何信息；`renderedCoordinate` 对非有限值渲染 "?"，不再 `Int(Double)` trap。

### 🧠 Design Intent (Why)
截图与坐标映射必须来自同一几何，不然模型按截图坐标点击会点到别处；上游 AX 的几何不可信时宁可缺少 frame，也不能让整个 helper 进程崩溃。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/WindowCaptureGeometry.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`

### 2026-11-07 维护者补充验证

- 基于最新 main 解决发布记录冲突，保留贡献者原提交。
- 补齐快照、query 与点击重读的 AX 几何校验；过滤负尺寸和相对坐标溢出，保护窗口面积及截图尺寸整数转换。
- 新增截图路径选择 / 非法 frame 回归与真实 AppKit fixture。v1.1.4 同一 fixture 复现左右出屏裁剪及 NaN 位置 / 尺寸导致 MCP SIGTRAP；修复后 8 个实测场景全部通过，验证完整色块、缩图、坐标点击、query 和非法几何出现后的正常读取与点击。
- `swift test`：442 项，9 跳过，0 失败；现有真实点击命中与误点保护 smoke 通过。
- 验证方式与限制见 [macOS 截图几何](../../macos-snapshot-geometry.md)。
