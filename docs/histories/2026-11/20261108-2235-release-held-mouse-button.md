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
