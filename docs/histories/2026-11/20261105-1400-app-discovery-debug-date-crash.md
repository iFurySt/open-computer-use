## [2026-11-05 14:00] | Task: 修复 debug 构建下 `Date` 比较导致的段错误

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude desktop (Code)`

### 📥 User Query
> 把 OpenComputerUseKit 以 SwiftPM 依赖嵌进另一个 macOS app 做集成测试时，debug 构建调用 `list_apps` 立即 SIGSEGV；先回上游修。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **[DateComparison]**: 新增 `package extension Date { isBefore / isAtOrAfter }`，按 `timeIntervalSinceReferenceDate` 比较，不经由 `Date` 的 `Comparable` 见证。
- **[调用点]**: `AppDiscovery.recentApps`、`AccessibilitySnapshot` 的 `BlockingAsyncBridge.waitForSignal`、`ComputerUseService` 与 `LockedUseDiagnostics` 的 deadline 轮询、app 的 `MacOSAppAgentProxy` 等待循环，全部改用该扩展。

### 🧠 Design Intent (Why)
在 Xcode 26.6（Swift 6.4.2）+ macOS 27.2 上，`swift build`（debug，`-Onone`）产物里每一处 `Date` 之间的 `>=` / `<` 都会跳转到地址 0 而崩溃：`ocu call list_apps` 在 `AppDiscovery` 崩，`swift test` 在 `BlockingAsyncBridge.waitForSignal` 崩（`testBlockingAsyncBridgeTimesOutScreenshotWork`）。lldb 里两个 `Date` 值都正常，`frame #1` 是 `static Date.>= infix()` 的编译器生成代码。release 构建把比较内联掉，所以 npm 发布包不受影响，但任何以 debug 方式构建 Kit 的调用方都会复现，仓库自己的 `swift test` 在该工具链上也跑不完。改为比较原始秒数绕开该见证，语义不变（`Date` 的比较本身就定义在 `timeIntervalSinceReferenceDate` 上）。`LockedUseConnection` 里的 `startupDeadline` 是 `TimeInterval`，不受影响。

### Validation
- `swift build`（debug）+ `ocu call list_apps` 正常返回目录。
- `swift test`：XCTest 包不再 signal 11，410 项中仅 `CursorWindowFollowTests` 一项因依赖真实前台窗口失败（与本改动无关）；修改前同一命令在 `BlockingAsyncBridge` 处崩溃。
- `make check-docs` 通过。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/DateComparison.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LockedUseDiagnostics.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/MacOSAppAgentProxy.swift`
- `docs/histories/2026-11/20261105-1400-app-discovery-debug-date-crash.md`
