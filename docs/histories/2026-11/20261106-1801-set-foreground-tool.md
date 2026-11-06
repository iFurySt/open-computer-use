## [2026-11-06 18:01] | Task: 新增 set_foreground 工具借用 / 归还前台

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 弹层、菜单、日期选择器、行内编辑器只在应用处于前台时出现；Agent 需要一个受控的方式把应用临时切到前台并在步骤结束后还回去。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[ForegroundBorrow]**：`borrow(app:)` 激活目标应用并记住之前的前台应用（LaunchServices 回退），`returnFocus()` 归还；会话结束（`endSession`）时兜底归还。
- **[工具]**：`set_foreground {app, mode: borrow | return}`，默认 borrow；描述里要求切换后重新观察。
- **[测试]**：工具计数更新为 12。

### 🧠 Design Intent (Why)
把"抢前台"做成显式、可归还的动作，而不是让 click 隐式激活应用：用户不该在 Agent 结束后发现焦点还停在被操作的应用上。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ForegroundBorrow.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
