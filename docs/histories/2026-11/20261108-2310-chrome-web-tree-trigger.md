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

### 2026-11-16 维护者复核

- 保留生产修复的小范围：每次 snapshot/query 写标志后仅多读一次 app AXRole，不进入 rewalk 循环。
- live test 使用独立 profile 和精确 PID，可与用户 Chrome 共存；清理等待有上限，启动失败清理临时目录，只在自有 Chrome 抢到前台时恢复原应用。按钮断言收紧为 button Go，并检查前台不变。
- 新增 `scripts/tests/fixtures/MacOSChromeTreeProbe.swift` 独立真实 AX 对照；六轮交错使用全新临时 Chrome，未关闭已有浏览器，均找到自有页面按钮且前台未变。baseline 2029–2075 ms，role read 144–160 ms。
- 完整 SnapshotBuilder live test 的基线被本机 Locked Use 校验阻断：XCTest 未签名身份报 invalidSignature；正常签名独立 probe 报 peerUnavailable(57)。没有绕过校验或修改安装。这条调用链未计为通过；上述直接 AX probe 只验证 Chrome 建树机制。
- 使用 `swiftc -parse-as-library scripts/tests/fixtures/MacOSChromeTreeProbe.swift -o /tmp/ocu-chrome-tree-probe` 构建，执行临时产物复现。需要正常解锁和 AX 权限。
- 合并 #170 前 Swift 483 项（11 skipped，0 failures）与 make ci 通过；合并后补跑 Swift 全套。
