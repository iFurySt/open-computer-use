## [2026-11-07 09:30] | Task: AX 文本插入被静默忽略时改走键盘

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 在 Pages 空白文稿正文上 `type_text`，调用返回成功，正文却仍是空的；`set_value` 随后校验失败。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[type_text]**：AX 插入（AXSelectedText / AXValue）之后读回 AXValue；前后相同且控件允许键盘回退时，改用真实键盘事件重打一遍；前后值不可读则信任写入结果。

### 🧠 Design Intent (Why)
Pages 正文这类自绘文本视图把 AX 写入当作无操作却返回成功，模型只能在下一次观察才发现没写进去。只在"读回确认没变"时才改走键盘，避免对已经写进去的控件重复输入。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`

### 追加（2026-11-09）：读回改轮询，选区变化也算落地，按进程记忆

评审指出三点，均已采纳：

- **读回可能先于写入生效。** 原来写完只读一次（`OPEN_COMPUTER_USE_ACTION_READ_BACK=0` 时还是立刻读），Chrome 的 AXValue 写入 8–15 ms 后才读得到，读到旧值就会用键盘再打一遍。现在每 5 ms 轮询，值或选区一变就停，300 ms 内都没变才判定被无视；发键之前再读最后一次。
- **值不变不等于没写进去。** `type_text("abc")` 盖在已选中的 "abc" 上，AXValue 前后相同，只有 `AXSelectedTextRange` 从 (0,3) 变成 (3,0)。`textInsertionLanded(before:after:)` 同时比对值和选区；两者都读不到才返回 nil（信任写入）。
- **按进程记忆。** 证实无视 AX 插入的进程记 pid + 启动时间（`NSRunningApplication.launchDate`，pid 复用时不匹配），同一进程后续 `type_text` 直接走键盘，省掉每次 300 ms 的等待。

纯函数 `textInsertionLanded` / `processLaunchIdentityMatches` 有单元测试；Chrome / Pages 的真机复测未做。
