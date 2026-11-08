## [2026-11-08 22:21] | Task: 动作前核对 element_index 仍是快照里那个控件

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> get_app_state 之后 app 把两个按钮的标题互换，再点快照里显示为 "Alpha" 的序号，按下的是现在叫 "Beta" 的那个。先在 main 上复现。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[ElementIdentity]**：快照渲染时为每个元素记下 role、subrole、名称（title，否则 description）、identifier；value 只对静态文本和弹出按钮记（那里 value 就是名称）。读的都是批量缓存里已有的属性，不多发 AX 消息。
- **[动作前核对]**：`lookupElement` 在任何输入前用一次批量读取核对当前身份。一致就照常；不一致就在窗口里找身份相同的元素，恰好一个才改绑到它，零个、多个或搜索被上限截断都报错，什么都不发。app 不回应核对时报错，不当成控件变了。
- **[测试]**：`ElementIdentityTests`。

### 🧠 Design Intent (Why)
快照保存的是 AXUIElement 引用。app 复用控件（标题互换、表格单元复用）后，引用还在，指向的却是另一个意义的控件。main 上 3 次都按到了 "Beta"；改名成 "Gamma" 时也照按。输入框的 value 是输入内容、复选框的 value 是状态，每次使用都会变，所以不算进身份，否则第二次操作同一个控件就会被拒。未变的控件只多一次批量读取（按钮上 p50 0.026 ms）。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ElementIdentity.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ElementIdentityTests.swift`
