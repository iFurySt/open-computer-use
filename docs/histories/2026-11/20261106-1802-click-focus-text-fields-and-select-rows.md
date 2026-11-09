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

### 追加（2026-11-09）：选行只对行 / 单元格 / 无 AXPress 的目标，写入发出后不再往下走

评审指出三点，均已采纳：

- **行里的控件被选行吞掉。** `selectContainingRow` 原来对任何祖先里有 AXRow 的元素都先选行并返回，outline 行里的 checkbox、展开三角、按钮永远按不到。现在 `clickShouldSelectContainingRow(role:actions:)` 只在目标本身是 AXRow / AXCell，或目标没有自己的 AXPress 时才走选行。
- **写入已发出就不再换路。** `AXFocused` / `AXSelected` 写入只有 attributeUnsupported、actionUnsupported、illegalArgument、noValue、notImplemented、invalidUIElement 能证明没生效；`.failure` / `.cannotComplete`（AppKit 对已执行的写入也答 -25205）按"已投递"处理。投递后核实超时（焦点 300 ms、选行 400 ms）不再落到 AXPress / AXConfirm（会把搜索提交掉、或进到单元格开始编辑），而是算作已处理，并在 click 结果里附一句"已投递未核实，先 get_app_state"的说明。焦点落在字段内部的编辑器（Preview 的 PDF 表单字段）也算核实通过，往上数四层。
- **行本身不可设时写容器。** 把 `[row]` 写进所属 AXOutline / AXTable 的 `AXSelectedRows` 或 `AXSelectedChildren`（哪个可设用哪个），读回核实行在其中。
- 固定的 150 ms / 30 ms 等待改成每 5 ms 轮询到变化为止，不受 `OPEN_COMPUTER_USE_ACTION_READ_BACK` 影响。

纯函数 `clickShouldSelectContainingRow` / `accessibilityWriteProvesNothingApplied` 与说明文案有单元测试；Contacts / Notes 的真机复测未做。
