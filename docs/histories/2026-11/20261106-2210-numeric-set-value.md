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

### 追加（2026-11-07 17:00）：直接写入后来回步进一次

Music 迷你播放器的音量滑块：直接写 AXValue 只改显示、不触发动作，应用音量不变。直接写入核实后，有步进动作就来回各走一步（顶到上限则先减后加），净值不变，最后再核对。本地复核：Music 音量 100 → 51，系统设置音量滑块不受影响。
