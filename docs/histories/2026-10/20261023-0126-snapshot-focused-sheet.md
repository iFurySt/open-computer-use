## [2026-10-23 01:26] | Task: 以 app 的 focused sheet 作为 snapshot root（#82）

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS 27.2 arm64`

### 📥 User Query
> 排查 #82：Firefox 打开原生文件选择器后，截图里有选择器，但 AX tree 和后台输入都落在底下的网页上。找到真实原因，用最小改动修复。

### 🛠 Changes Overview
**Scope:** macOS snapshot 窗口选择、`query` 的 window_id 回查、单测、参考文档、功能发布记录。

**Key Actions:**
- **根因**：Firefox 用 `beginSheetModalForWindow:` 把 `NSOpenPanel` 作为 sheet 弹出。sheet 是 app 的 `AXFocusedWindow`，role 是 `AXSheet`；`isUsableWindowElement` 只接受 `AXWindow`，于是 root 回退到 `AXWindows` 里的网页窗口。Gecko 的窗口只把 mozAccessible 和标题栏按钮放进 `AXChildren`，所以 tree 里没有面板。0.3.5 的截图靠标题 / 面积启发式选中了叠在前面的 sheet 窗口，于是“截图有、tree 没有”；当前 main 精确绑定后，截图也只剩网页。原生 AppKit 窗口的 `AXChildren` 含 sheet，tree 有面板，但截图同样没有。
- **root**：新增 `isSnapshotRootRole`，`AXSheet` 与 `AXWindow` 一样可作 root。sheet 有自己的 `CGWindowID`，tree、截图、元素坐标和输入目标随之都落在面板上。
- **query**：`windowElement(for:)` 在 `AXWindows` 找不到时再看 focused window。否则 query 到 sheet 里的控件后，再操作会报 “window_id … is not a current window”。
- **agent display**：root 是 sheet 时，`window_placement=agent_display` 停靠 sheet 的 `AXParent` 窗口，并用父窗口自己的 `CGWindowID` 记录，`restore` 也按父窗口恢复。sheet 不能单独移动（AX 接受位置但不动），跟着父窗口走，和修复前一样。

### 🧠 Design Intent (Why)
sheet 挡住整个父窗口，可交互的只有它，所以直接以它为 root，和 `runModal` 弹出的独立对话框（本来就是 `AXWindow` / `AXDialog`）行为一致。改在窗口选择这一处，`get_app_state`、动作后的刷新和 `query` 共用。

### ✅ Verification
- 新单测 `testSnapshotRootsAtFocusedSheet`：去掉 `AXSheet` 时失败；`OpenComputerUseKitTests` 全套 380 项通过（7 skipped）。
- 实机（macOS 27.2，后台，前台 app 不变）：用一个非沙盒测试 app 弹出 `NSOpenPanel`，分 sheet、模仿 Gecko 过滤 `AXChildren` 的 sheet、`runModal` 三种。修复前，Gecko 式 sheet 的 tree 和截图都只有底下的窗口，`query` 找不到 Cancel，Escape 无效；修复后两种 sheet 的 tree 与截图都是面板，按快照索引和 `query` 索引点击 Cancel 都能关闭面板，Gecko 式 sheet 上按截图坐标（`auto`）点击也能关闭。`runModal` 前后一致。
- agent display 实机（单屏，sheet 打开、app 在后台）：`window_placement=agent_display` 把父窗口和 sheet 一起移到 agent display；sheet 未关时 `restore` 两者回到原坐标并移除显示器；再次停靠后按索引点击 Cancel 可关闭面板。显示器排列与前台 app 前后不变。sheet 关闭时父窗口自行回到原坐标，main 上同样如此（AppKit 行为）。
- 未覆盖：后台 `press_key` 和 `sky_click` 的原始事件进不了由 openAndSavePanelService 托管的面板内容，修复前后一致。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/references/macos-window-visibility-and-spaces.md`
- `docs/releases/feature-release-notes.md`
