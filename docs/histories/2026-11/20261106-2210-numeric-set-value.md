## [2026-11-06 22:10] | Task: 数值控件的 set_value

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 对滑块 `set_value` 报 -25201；系统设置里的音量滑块直接写入被无视，只有 Increment / Decrement 生效；滚动条 `set_value` 同样 -25201。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[set_value]**：元素当前 AXValue 是数值时，解析请求值（纯数字或 "25%"），按同类型 CFNumber 写入并核实。
- 写入被拒或没生效时，用 AXIncrement / AXDecrement 逐步逼近，停在最接近的可达值；跨过目标就退回一步；完全动不了才报错。
- 非数值控件保持原来的字符串路径。

### 🧠 Design Intent (Why)
滑块 / 滚动条 / 步进器的 AXValue 是数值，CFString 写不进去；SwiftUI 滑块只认步进。模型拿到的最终值在动作结果的状态里，由它自己核对。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
