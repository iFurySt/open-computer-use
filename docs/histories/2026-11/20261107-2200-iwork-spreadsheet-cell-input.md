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

### 追加（2026-11-09）：AXSelectedCells 优先
上游 reviewer 指出：Numbers 的单元格选区是 `AXTable` 上的 `AXSelectedCells`，vercel-labs/agent-desktop 的 `ax_probe.swift` 直接向它写 `[cell]` 就能选中并读回，不依赖全局指针门。本次在 `performAXClickSequence` 里、`performPreferredClick` 之前加了一级 AX 选中路径：

- **触发条件**：左键单击，命中元素角色是 `AXTable` / `AXColumn` / `AXRow` / `AXCell`，且应用是 iWork bundle（`isIWorkSpreadsheetClickRole(role:bundleIdentifier:)`）。双击不走这层——Numbers 里双击是进入编辑态，写选区表达不了。
- **定位单元格**：先沿 `AXParent` 找自身或最近的 `AXTable`（最多 8 层）。命中的已是 `AXCell` 就直接用；否则读表的 `AXVisibleCells`（截断 4096 项），用每格的 `AXPosition + AXSize` 全局框反查包含点击点、面积最小的那格（`spreadsheetCellContaining(point:cells:)`）。没有任何格包含该点 → 返回 false。
- **写入与读回**：`AXUIElementIsAttributeSettable(table, AXSelectedCells)` 为假 → false。写 `[cell]`；返回 attributeUnsupported / actionUnsupported / illegalArgument / noValue / notImplemented 视为"写入未被接受"直接 false，其余结果（含 `.success`）一律靠读回判定：每 5 ms 读一次 `AXSelectedCells`，最多 400 ms，数组里出现 `CFEqual` 的该格才算成功。
- **失败闭合**：任何一步拿不到证据都返回 false，接着照旧走 `prefersPointerDeliveryOverAXPress` → 指针路径（`performNonAXClickFallback`）。全局指针门开着时，AX 层选不中的行为与之前完全一致。

**验证状态：尚未在真实 Numbers 文档上验证**，只有单元测试（`testIWorkSpreadsheetClickRole*`、`testSpreadsheetCellContaining*`，连同原有 13 项通过）。Numbers 是否真的暴露 `AXVisibleCells` / 可写的 `AXSelectedCells` 仍待 maintainer 实机确认；确认前指针路径仍是实际生效的兜底。

维护者可用下面的探针（Swift，`swiftc probe.swift` 后在 Numbers 打开任意表格运行）确认两个属性是否暴露：

```swift
import AppKit
guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Numbers").first?.processIdentifier else { exit(1) }
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func walk(_ e: AXUIElement, _ depth: Int) {
    guard depth < 25 else { return }
    if attr(e, kAXRoleAttribute) as? String == kAXTableRole as String {
        let visible = attr(e, kAXVisibleCellsAttribute) as? [AXUIElement] ?? []
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(e, kAXSelectedCellsAttribute as CFString, &settable)
        print("table visibleCells=\(visible.count) selectedCellsSettable=\(settable.boolValue)")
        if let cell = visible.first { print("set:", AXUIElementSetAttributeValue(e, kAXSelectedCellsAttribute as CFString, [cell] as CFArray).rawValue) }
        print("selected:", (attr(e, kAXSelectedCellsAttribute) as? [AXUIElement])?.count ?? -1)
    }
    (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).forEach { walk($0, depth + 1) }
}
walk(AXUIElementCreateApplication(pid), 0)
```
