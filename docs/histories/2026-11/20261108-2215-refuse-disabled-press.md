## [2026-11-08 22:15] | Task: 拒绝按下禁用的控件

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> AppKit 对禁用按钮的 AXPress 回 success，点击看起来送达了，其实什么都没发生。按之前先读 AXEnabled，禁用就明确报错。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[click / perform_secondary_action]**：用 element_index 指定的控件在发出任何输入前读一次 AXEnabled；为 false 时报错「element N is disabled, so nothing was sent」。
- **[菜单项例外]**：AXMenuItem / AXMenuBarItem 放行：菜单关着时，菜单项的 AXEnabled 停留在上次打开时的状态，交给 app 自己决定。
- **[测试]**：`disabledControlRefusal` 的单元测试。

### 🧠 Design Intent (Why)
快照里已经把控件标成 `disabled`，但动作路径不看。main 上对禁用的 NSButton 点击、对禁用的 NSSlider 做 Increment，都返回成功，按钮动作没有执行、滑块值没变。人点禁用控件不会有任何效果，所以这里在发出输入前拒绝，而不是报告成功。读的是当前的 AXEnabled，不是快照里的旧值。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
