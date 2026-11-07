## [2026-11-06 18:00] | Task: 把打开的菜单并入快照与 query

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code desktop`

### 📥 User Query
> 模型点开菜单栏菜单 / 弹出按钮后，`get_app_state` 和 `query` 里永远没有菜单项，只能反复点同一个按钮。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[AXActiveMenu]**：只读的活动菜单发现（`readActiveAXMenus` / `captureActiveAXMenus`）：菜单栏 `AXSelectedChildren`、焦点链、AXVisible / AXExpanded、可见子项与 CG 菜单窗口几何证据逐层证明"打开"；预算有限（无候选 80ms、有候选 300ms、单次 IPC 40ms），超时丢弃整棵树。
- **[快照]**：先渲染活动菜单根再渲染窗口；菜单项按控件排序；活动菜单只走发现阶段验证过的边，不读实时 children。
- **[query]**：活动菜单作为额外搜索根；`currentGeometry` 允许仍在活动菜单里的元素不属于窗口。
- **[click]**：菜单栏项 / 弹出按钮 / 菜单按钮按下后最多等 0.6s 菜单出现。
- **[证据]**：macOS 27 的 Contacts 打开菜单时菜单栏项与 AXMenu 的 `AXExpanded` 仍为 false、`AXVisible` 不支持、CG 菜单窗口比 AX 内容区四边各大 75pt；菜单栏 `AXSelectedChildren` 认证可覆盖 `AXExpanded=false`，几何证据接受 layer>0 窗口的有限内边距（≤96pt）。

### 🧠 Design Intent (Why)
菜单不是窗口的子树，原有的快照和 query 永远看不到它；发现逻辑只读、不授权输入，所有证据都要独立成立并在结束前复核，避免把半关闭的菜单渲染出来。预算不能太紧：画中画 / 录屏让 SwiftUI 应用的 AX 响应从 <1ms 涨到 20–30ms。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AXActiveMenu.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AXActiveMenuTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AXActiveMenuGeometryTests.swift`

### 追加（2026-11-07 16:20）：AXPress 过的子菜单父项也要认成打开

Music「File → New」：AXPress 父项 New 后子菜单实际打开（CG 多出一个菜单窗口），但 New 的 `AXExpanded` 仍为 false，`isOpen` 把它的 AXMenu 子节点拒掉，模型看不到「Playlist Folder」。现在父项 `AXSelected=true` 与 ancestors 认证同等看待，子菜单仍要几何等独立证据。本地复核：点 New 后子菜单 5 项进树。
