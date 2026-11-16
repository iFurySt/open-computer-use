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

### Maintainer follow-up (2026-11-09)

- 基于已合并 #178/#164 的最新 main 解决冲突。抽出生产连击序列供测试覆盖，补首次拒绝/超时、部分成功后拒绝/超时、正常双击、AXOpen 不重复。
- 新增可重复的真实 AppKit 慢按钮脚本：修复前连续 3 轮每次投递 3 次、约 6.2 秒且返回成功；修复后每次 1 次、约 1.5 秒返回不确定结果。快速单击和有意双击分别准确执行 1/2 次。
- Swift 457 项（9 跳过）无失败；签名 release app 构建通过；点击几何、后代保护回归通过。桌面有活动，使用既有 allow-desktop-activity 模式，不声称本轮验证了前台/物理指针稳定。
- 文件面板首次运行与另一 GUI probe 重叠时出现一次取消异常；改为独立顺序运行，旧版与修复版各 12 个 custom/filtered/plain/modal × snapshot/query/coordinate 场景均通过。最终证据使用顺序运行。
- 文档与入口见 `docs/click-outcomes.md`。不改系统授权、不启用全局指针；Linux 临时容器已清理。
