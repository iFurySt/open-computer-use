## [2026-11-05 12:40] | Task: 修正无资源构建下软件光标静止朝向

### Execution Context
- Agent: Claude Code
- Runtime: macOS 26 arm64, Swift 6.3.1

### User Query
> 光标为什么朝下？正常应该朝上。用 computer-use 时看起来是倒的。

### Changes Overview
- `SoftwareCursorGlyphMetrics.proceduralContourNeutralHeading` 由 `-96.5°` 改为 `-45°`，`pointerArtworkRotation` 随之从 `+38.5°` 变为 `-90°`。
- `SoftwareCursorGlyphRenderer.draw` 新增 `usesReferenceArtwork: Bool = true` 参数，使回归测试能强制走 procedural fallback 分支；运行时行为不变。
- 修正 `testSoftwareCursorGlyphArtworkNeutralHeadingMatchesCursorMotionBaseline` 的符号：drawing space 里 contour heading 与 `pointerArtworkRotation` 同向相加，原用例写成相减，导致常量可以自洽却整体偏转 135°。
- 新增 `SoftwareCursorGlyphDirectionTests`：渲染 artwork 与 fallback 两条路径，用凸包最锐顶点求 apex heading，断言两者一致且落在 `targetNeutralHeading`（上左）±15° 内。
- 未改动参考图渲染路径、Cursor Motion demo、点击链路与权限逻辑。

### Design Intent
overlay 有两套 glyph：bundle 内带 `Resources` 时画官方参考图，其余（每个 CLI、Linux、`swift build` 直跑）退回 `pointerPath` 程序化轮廓。参考图本身朝向正确，fallback 却因为轮廓 neutral heading 用了错误符号而整体偏转约 135°，表现为鼠标指针旁边多出一个朝下的三角。两套路径必须落在同一个 heading 上，这条不变量现在由渲染级回归锁定，而不是由常量之间的算术恒等式锁定。

### Validation
- 复现：修正前渲染 fallback，凸包 apex heading 为 `-66.8°`；参考图为 `-137.6°`；目视两者朝向相差约 135°。
- 修正后 fallback apex 为 `-132.9°`，与参考图一致；`swift test` 全量 430 个用例通过（8 skipped，0 failure）。
- 新增用例在旧常量下失败（`-66.79` vs `-137.57`，容差 15°），在新常量下通过，确认能拦住回归。
- 未在带 `Resources` 的打包 `.app` 内复测，该路径未改动；CLI 构建的 fallback 为本修复的直接目标。

### Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorGlyphRenderer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/SoftwareCursorGlyphDirectionTests.swift`
- `docs/releases/feature-release-notes.md`
