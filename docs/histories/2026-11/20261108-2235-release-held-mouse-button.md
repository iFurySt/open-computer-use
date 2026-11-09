## [2026-11-08 22:35] | Task: 拖拽或点击中途失败时松开鼠标键

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 拖拽或组合键中途出错时，不能让鼠标键或修饰键一直按着。先复现。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[释放不受拒绝]**：鼠标抬起事件不再先过会话检查；按下之后检查失败也一定发出抬起。
- **[拖拽]**：`dragTargeted` / `dragGlobally` 在拖动中途出错时，先在停下的位置发出 leftMouseUp，再抛出错误。
- **[测试]**：`DragReleaseTests` 把事件发给测试进程自身并读回事件队列，用 `LockedUseActionScope.withValidator` 在第 3 次检查时模拟租约结束。

### 🧠 Design Intent (Why)
每个鼠标事件发出前都会调用 `requireUsableComputerUseSession()`。Mac 锁屏或 Locked Use 租约在按下之后结束时，检查抛错，抬起事件再也不会发出：app_post 路径下目标 app 停在拖拽状态，全局路径下整个桌面的左键保持按下。main 上两个用例都只收到 mouseMoved、leftMouseDown。

组合键未改：`pressKey` 只在开始时检查一次，修饰键按下后到抬起之间唯一的失败点是 `CGEvent` 创建返回 nil，无法复现。

### ✅ Validation
- `DragReleaseTests`：main 上拖拽和点击都只有按下没有抬起（2 项失败），修复后都收到 leftMouseUp。
- `swift test`：455 项，8 跳过，0 失败。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/DragReleaseTests.swift`

### Maintainer review

- 基于最新 main 整合。抬起事件在按下之前创建；只有本次按下成功，才注册不受后续租约撤销影响的配对释放。普通事件仍检查会话，不给任意 mouse-up 通用豁免。
- 拖拽失败时保留原错误，在最后成功投递位置释放；抬起沿用按钮、click count 和全局 gesture，并更新投递时间。
- 本机真实 AppKit 事件队列对照：main 的点击/拖拽撤销用例缺少抬起；修复版本通过。按下前拒绝不释放，纯逻辑清理测试也通过。没有实际锁屏或改动用户文档。
- Swift 全套 461 项、9 skipped、0 failures；最终时间戳调整后 4 项配对释放回归再次通过，包含真实事件队列；文档与 diff 检查通过。
