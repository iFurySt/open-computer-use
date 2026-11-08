## [2026-11-08 21:15] | Task: 密码框的值不再读取

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 快照、query、type_text、set_value 都会读密码框（`AXSecureTextField`）的 AXValue；改成从不读取。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[isSecureTextField]**：快照渲染与 `ComputerUseService` 的 AXValue 读取先看 subrole，密码框一律返回 nil；渲染时 subrole 已在批量读取里，不多一次 AX 调用。
- **[query]**：批量扫描带上 AXSubrole，密码框的值不参与匹配、不进结果。
- **[set_value]**：密码框写入后不回读校验。

### 🧠 Design Intent (Why)
AppKit 的 `NSSecureTextField` 对 AXValue 回答空串。`type_text` 把空串当作当前文本，在其上拼接后整体写回：框里原有的 `hunter2-planted` 被替换成只剩 `X`，并报 "value changed after writing"。`set_value` 写入成功却因回读不到而报错，诱导重试。若某个 app 明文回答密码，它还会进入快照、query 结果和日志。不读取后，`type_text` 走键盘输入，在光标处插入；`set_value` 写入即返回。

### ✅ Validation
- `AXSemanticRenderingTests.testPasswordFieldValueNeverReachesTheSnapshot`：明文回答值的密码框，main 上值出现在快照中（失败），修复后通过。
- `scripts/tests/macos-text-input-smoke.mjs` 新增密码框一段（真实 `NSSecureTextField`，值 `hunter2`，光标在末尾）：main 上 `type_text "X"` 后框内只剩 `X` 并报错（该段失败），`set_value` 写入后报 "could not verify"；修复后为 `hunter2X`，`set_value` 成功，快照不含密码，整套 smoke 通过。
- `swift test`：454 项，8 跳过，0 失败。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AXSemanticRenderingTests.swift`
- `scripts/tests/fixtures/MacOSTextInputFixture.swift`
- `scripts/tests/macos-text-input-smoke.mjs`
