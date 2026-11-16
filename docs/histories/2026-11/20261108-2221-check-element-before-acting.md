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

### Maintainer review: final behavior

基于最新 main，收紧为只验证原 AX 引用，身份变化/引用失效/读取失败就拒绝并要求重新 get_app_state，不按同名控件自动改绑。这样避免误选替代对象，也移除了动作路径上的整树搜索和额外时间预算。名称、role/subrole、identifier 与静态文字/弹出按钮的值参与身份；普通文本内容和复选状态不参与。

读取当前 role/subrole 后才按需要读取 AXValue；不批量读取任意候选的值，保留密码保护。属性级 AX 错误也不能当成普通缺失值；无 role 的身份不通过。

真实 AppKit/native MCP 对照：main 在 Alpha 改成 Beta 后用旧索引按到了 Beta；修复版拒绝且计数不变，重新观察后能正确点击 Alpha。再次改名同样拒绝；普通文本框用同一索引连续 set_value 两次正常。脚本：scripts/tests/macos-element-identity-smoke.mjs，baseline 可加 --baseline。测试只使用临时自有窗口，不操作用户文档。

最终验证：Swift 463 项、9 skipped、0 failures；真实 NSOpenPanel 12 组快照/查询/坐标矩阵与 AppKit 文本/密码回归通过，文档检查通过。
