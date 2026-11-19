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

### 追加（2026-11-09）：按 review 意见补齐"读不到 / 截断 / 快速无菜单路径 / 窗口按钮排序"

上游 PR #151 的 review 指出四个问题，本次一并修正：

- **读失败不再伪装成"没有菜单"**：`AXActiveMenuTree` 新增 `menuWindowUnreadable`。进入 AX 发现前先读一次在屏 CG 窗口列表（`AXMenuWindowTriage`）；目标进程拥有 `kCGPopUpMenuWindowLevel` 的在屏窗口（不含目标窗口本身）而 AX 发现失败、超时或没有候选时，`readActiveAXMenus` 的每条失败路径都返回带该标记的空树。快照在菜单项之后、窗口树之前渲染一行 `[A menu appears to be open but did not answer accessibility reads; do not click its opener again. Press Escape to close it or take a screenshot.]`，`query` 结果以 `notes` 数组携带同一句；`waitForOpenedMenu` 也把它视为"菜单已打开"。只有菜单层级（101）的窗口才作为这条提示的证据，浮动面板 / tooltip 等其他 layer > 0 窗口只触发发现、不触发提示。
- **无菜单的廉价路径**：没有 layer > 0 的在屏候选窗口就直接返回"无菜单"，不创建任何 AX 句柄、不花 80ms 预算；这份 CG 列表随后复用为首次几何佐证（原来是懒读），结束前的复核仍重新读取。CG 读取改为 `[.optionOnScreenOnly, .excludeDesktopElements]`。
- **截断可见**：菜单节点上限从 `min(maximumNodes, 256)` 改为 `max(maximumNodes, 2048)`（`AXMenuDiscoveryBudget.minimumNodes`），时间预算不变。`walk` 因节点 / 深度上限停下时置 `truncated` 并统计已进树的菜单项数；快照渲染 `[menu truncated: N items shown, more exist]`，`query` 在窗口遍历完整时把 `stop_reason` 改为 `menu_truncated`（`truncated: true`）并在 `notes` 携带同一行。上限检查放在任何 IPC 之前，避免到顶后继续读角色把预算耗尽、整棵树反被丢弃。
- **窗口红绿灯按钮最后搜**：`partitionWindowChromeButtons` 按 `AXCloseButton` / `AXMinimizeButton` / `AXZoomButton` / `AXFullScreenButton` 子角色把 AXWindow 直接子节点里的窗口按钮摘出，窗口遍历结束后再作为额外根搜索，纯 `role: button` 查询不会把关闭按钮排第一。只改 `query` 顺序，不改快照渲染。
- **文档**：`docs/targeted-query.md` / `docs/targeted-query.zh-CN.md` 补充 `notes`、`menu_truncated` 与窗口按钮排序说明。
- **文件拆分**：`AXActiveMenu.swift` 超过 400 行上限，CG 窗口证据与分流拆到 `AXMenuWindowEvidence.swift`，AXUIElement 读取器与预算拆到 `AXMenuSystemReader.swift`；`AXActiveMenu.swift` 只留泛型发现算法、结果类型与 `captureActiveAXMenus` 入口。

**未覆盖**：review 提到 opener 的 AXPress 在菜单打开后才回 `cannotComplete`（约 6s 后），`performAction` 把它当"未处理"继续后续候选；本次未改动该路径。本机没有驱动真实应用验证提示行在快照里的位置与 CG 层级判定，单元测试覆盖的是纯逻辑（triage / unreadable / 截断 / 排序）。

**新增测试**（`AXActiveMenuTests`）：`testMenuLevelWindowWithoutReadableMenuIsReportedUnreadable`、`testWindowTriageSkipsDiscoveryWithoutMenuCandidateWindow`、`testNodeAndDepthCapsMarkTreeTruncatedAndCountShownItems`、`testWindowChromeButtonsArePartitionedAfterOtherCandidatesInOrder`。

补充：上限提到 2048 后，遍历不能把 300 ms 预算全部用掉，否则逐节点复核阶段超时、整棵树被丢弃，比原先显示 256 项更差。进入遍历时记下剩余预算，遍历只用其中 60%（`AXMenuDiscoveryBudget.verificationShare = 0.4` 留给复核），用完即按截断处理，已读到的部分照常发布。
