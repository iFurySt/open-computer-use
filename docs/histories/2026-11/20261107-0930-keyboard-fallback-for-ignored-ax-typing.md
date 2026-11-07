## [2026-11-07 09:30] | Task: AX 文本插入被静默忽略时改走键盘

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 在 Pages 空白文稿正文上 `type_text`，调用返回成功，正文却仍是空的；`set_value` 随后校验失败。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[type_text]**：AX 插入（AXSelectedText / AXValue）之后读回 AXValue；前后相同且控件允许键盘回退时，改用真实键盘事件重打一遍；前后值不可读则信任写入结果。

### 🧠 Design Intent (Why)
Pages 正文这类自绘文本视图把 AX 写入当作无操作却返回成功，模型只能在下一次观察才发现没写进去。只在"读回确认没变"时才改走键盘，避免对已经写进去的控件重复输入。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
