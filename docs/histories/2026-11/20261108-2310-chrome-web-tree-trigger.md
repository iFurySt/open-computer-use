## [2026-11-08 23:10] | Task: Chrome 新页面在第一次快照里就有网页树

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 新启动的 Chrome 第一次 get_app_state 要约 2 s 才拿到网页内容；查清 AXEnhancedUserInterface / AXManualAccessibility 写入后怎样让 Chrome 立即建树。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[enableBestEffortAccessibilityModes]**：写完两个 flag 后立即读一次 app 元素的 AXRole，不论 `AXManualAccessibility` 写入是否成功。
- **[WebTreeLiveTests]**：opt-in（`OPEN_COMPUTER_USE_RUN_WEB_TREE_LIVE_TEST=1`），每轮启动临时 profile 的独立 Chrome，保持用户前台 app 不变，测第一次快照耗时并要求包含页面按钮，按 PID 结束。

### 🧠 Design Intent (Why)
flag 之后紧接着读 app 元素的 AXRole，Chrome 12–19 ms 内建好页面树；不读则约 2.03 s，期间读焦点窗口、窗口列表、整棵树都不会加快。Chrome 对 `AXManualAccessibility` 回答 -25205（不支持），所以这次读取不能放在写入成功的分支里。flag 仍然每次快照只写一次，不在轮询里重复写。

### ✅ Validation
- `WebTreeLiveTests`，各 5 个全新 Chrome：main 上第一次快照 2099–2171 ms（首次遍历没有页面，靠 100 ms 一次的重走等到约 2 s）；修复后 127–190 ms，首次遍历就有页面。用户前台 app 始终不变，无残留 Chrome 进程。
- `swift test`：454 项，9 跳过，0 失败。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/WebTreeLiveTests.swift`
