## [2026-11-07 22:00] | Task: iWork 电子表格单元格的点击与输入

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> macOSWorld T1 的三道 Numbers 题（改 Food 实际支出、清空预算数值、复制图表源表）全部以「界面操作超时」失败；主机日志里每次调用都成功。改 Kit。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[click]**：`performPreferredClick` 对 `AXColumn` 一律返回未处理。Numbers 的整列暴露 `AXPress`，执行后既不选列也不选单元格；坐标点击被命中测试解析成整列时原先就此算作"已处理"并返回 ok，现在落到指针路径（`performNonAXClickFallback`），点击真正落在单元格上。
- **[type_text]**：焦点停在 iWork（Numbers / Pages / Keynote）的 `AXTable` 或 `AXLayoutArea` 上时直接走键盘事件。这两类元素既不可写也读不出值，AX 文本插入没有落点、读回也无法识别；键盘事件才会开始编辑当前选中的单元格。限定 iWork bundle，避免把普通表格的 type-select 当成输入。新增 `prefersPointerDeliveryOverAXPress(role:)` / `prefersKeyboardTextInput(role:bundleIdentifier:)` 纯函数与调试日志（`OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS=1` 时打印焦点角色）。
- **[press_key]**：`KeyPressParser` 补齐标点键：`.` `,` `-` `=` `/` `;` `'` `[` `]` `\` `` ` `` 及对应的 X11 keysym 名字（period / comma / minus …）。模型往表格里敲小数时按字面给 `.`，原先报 unsupported key。

### 🧠 Design Intent (Why)
Numbers 不把单元格放进 AX 树（表格下只有当前选中的行列头），模型只能按截图坐标点单元格。原先 `auto` 坐标点击在画布上静默无效却返回 ok，模型随后在 JS 里等状态变化直到超时。修法只改"什么算已处理"和"焦点在画布时怎么输入"，不改变 `auto` 的投递顺序：未开 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` 时指针路径仍是 `app_post`，Numbers 对它同样无反应（`sky_click` / `global` 能选中），这是既有的安全门语义，本次不动。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/KeyMapping.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`

### ✅ 验证
- Numbers「Personal Budget」模板实测（`OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`）：`click(x, y)` 后 AppleScript 读到 selection range 为 C4；`type_text("305.75")` + `press_key("return")` 后 C4 = 305.75；`press_key(".")` 不再报错。
- 全局指针关闭：点击仍走 `app_post`、选区不变（既有行为）；键盘输入进入当前选中的单元格。
- `swift test --filter "testKeyPress|testSpreadsheetColumn|testIWorkCanvas|testKeyboardTextFallback|testTypeText"` 11 项通过（上游 `LockedUseIncidentReplayTests.swift` 在 Swift 6.4.2 下需临时把 `Replay` 的 `let` 改 `var` 才能编译，未提交）。
