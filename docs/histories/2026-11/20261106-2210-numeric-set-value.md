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

### 追加（2026-11-09）：按 review 意见改成轮询读回、不信返回码、停短即报错

上游 PR #156 的 review 指出四个问题，一次修掉：

- **读一次就下结论会把迟到的一步当成没动**：步进后固定睡 30 ms 读一次，值没变就 `break`，第一步就会抛 "Increment/Decrement had no effect"，而动作其实落地了（fixture 滚动条在 `AXScrollDownByPage` 返回后 0.2–14.3 ms 才动）。改为 `pollNumericValue`：每 5 ms 读一次直到值变化，400 ms 放弃；响应快的控件第一次读就命中。直接写入后的固定 100 ms 也换成同一轮询（直到落在目标附近），跨过目标的退回一步与 nudge 的两步同样等值变化，不再盲走。
- **不能按 `AXUIElementPerformAction` 的返回码判断**：AppKit 对确实执行了的动作也回 -25205（cannotComplete），`AXScrollDownByPage` 翻了页仍回 -25205。只有 `actionUnsupported` / `illegalArgument` / `notImplemented` 证明动作没跑（`axActionDidNotRun`），其余一律以读回的值为准。
- **停短要说出来**：原先撞到 200 步上限或步进不再改变值时返回 `true`，set_value 在不是请求的值上报成功。上限提到 1024；撞上限或步进卡住且仍在容差外时抛 "set_value stepped N times and stopped at X, short of Y for element i"。完全没动过仍是原来的 "could not change" 错误；跨过目标退回一步停在最接近的可达值仍算成功，最终值由状态回读给模型。
- **布尔 AXValue**：复选框 / 开关的 AXValue 是 CFBoolean，原先走字符串路径得 -25201。现在解析 `true` / `false` / `1` / `0`（忽略大小写和首尾空白）写 `kCFBooleanTrue` / `kCFBooleanFalse`，用 `verifySetValueReadBack` 核实；非布尔文本抛 invalidArguments。

步进逻辑收进 `NumericStepper`，纯逻辑（`parseNumericValue` / `parseBooleanValue` / `axActionDidNotRun` / `pollNumericValue`）补了单测。本机没有可用的真滑块，行为变化只过了单测和编译，没有在系统设置 / Music 的滑块上重跑。

