## [2026-11-08 22:09] | Task: 点击链在 AX 返回码说明不了时停下

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 一次点击不能落两次：AX 动作返回的错误码可能是在 app 已经执行之后给的，此时不能再换一种方式重发。先在 main 上复现。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[动作返回码分级]**：`clickActionRan` 只有 actionUnsupported / illegalArgument / notImplemented / invalidUIElement 视为「app 什么都没做」，点击链才继续下一种方式；failure / cannotComplete / attributeUnsupported / noValue 报错停下，说明可能已经生效。AXOpen 的 attributeUnsupported 仍按已执行处理。
- **[写入返回码分级]**：`clickAttributeWasSet` 用于点击链里的 AXSelectedChildren / AXMain / AXFocused 写入：属性拒绝的写入没生效，可以继续；failure / cannotComplete 停下。
- **[连击]**：第 2 次以后的 AXPress 被拒绝时报错，不再回退到别的方式（前面的已经发出）。
- **[测试]**：分级表的单元测试。

### 🧠 Design Intent (Why)
`performAction` 把 failure、cannotComplete 等都当成「没处理」，点击链接着走 AXConfirm、子元素、附近命中测试，最后用 app_post 鼠标点击。但这些返回码可以在 app 执行之后才到：主线程忙过 AX 超时（1.5 s）的按钮回 -25204，动作照常执行。main 上用一个动作耗时 2 s 的 AppKit 按钮复现：一次 `click` 按了 3 次、耗时 6.2 s、报告成功。修复后按 1 次、1.5 s 后报错，提示先读状态再重试。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
