## [2026-11-06 21:30] | Task: 浏览器地址栏打字走键盘事件

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 在 Chrome 地址栏用 `type_text` 填入 URL 后按 Return，页面不跳转，仍停在新标签页。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[type_text]**：焦点元素是浏览器窗口 chrome 里的 AXTextField（地址栏 / 搜索栏，不含 AXWebArea 下的网页输入框）时，跳过 AX 文本插入，直接走真实键盘事件。
- 浏览器按 bundle id 前缀识别：Chrome / Chromium / Safari / Firefox / Edge / Brave / Arc / Vivaldi / Opera。

### 🧠 Design Intent (Why)
Chrome 的 omnibox `AXSelectedText` 可写，AX 插入后只更新显示，omnibox 的输入模型没有收到输入，随后 Return 不导航；`set_value` + Return 或键盘打字 + Return 都能导航。地址栏的语义就是"用户键入"，走键盘事件最忠实。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
