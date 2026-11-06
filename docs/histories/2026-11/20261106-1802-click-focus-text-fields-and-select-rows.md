## [2026-11-06 18:02] | Task: 点击文本框要聚焦、点击行要选中

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 在 Contacts 里点搜索框后 `type_text` 报"没有聚焦的可编辑元素"，点侧栏分组行后选中项不变。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`、`scripts/node-repl`

**Key Actions:**
- **[click / 文本框]**：AXTextField / AXTextArea 先设 `AXFocused=true` 并核实应用的焦点元素确实换成了它，再走 AXPress / AXConfirm / AXOpen。SwiftUI 搜索框没有 AXPress，只有 AXConfirm（等于提交搜索）。
- **[click / 行]**：元素位于 AXRow（父级是 AXOutline / AXTable 而非 AXList）时，对该行设 `AXSelected=true` 并读回核实。
- **[press_key]**：接受 `ArrowUp` / `ArrowDown` / `ArrowLeft` / `ArrowRight`。
- **[REPL]**：`app.click({ x, y })` 与 `app.click([x, y])` 等价。

### 🧠 Design Intent (Why)
点击的语义应当落到控件的意图上：点文本框是为了输入，点一行是为了选中。原生 AX 实测（macOS 27.2 Contacts）这两类控件都没有 AXPress，原动作链要么走错动作要么静默失败。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/KeyMapping.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
