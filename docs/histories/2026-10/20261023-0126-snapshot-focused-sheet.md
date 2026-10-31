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

### 2026-10-31：PR #118 合并前复核

- 基于已合并 #126 / #127 的最新 main 合并分支，保留贡献者提交，解决发布记录冲突。
- 真实自定义 sheet 复现：点击根索引会按下内部 Cancel。将窗口索引的 Raise / focus 保护扩展到 sheet，避免扫描内部按钮。
- 真实 query 点击复现：控件的 AXWindow 指向父文档导致错误拒绝。AXWindow 不匹配时继续检查有界父链，关闭后的旧 sheet 仍须通过窗口 ID 和归属验证。
- query 的短读取超时会泄漏到动作，导致 Cancel 已关闭面板却报告失败。解析完成后恢复进程级默认超时，重新验证控件后恢复其默认超时，读操作保留原预算。
- 停靠 sheet 前确认父节点是独立 AXWindow；无法确认时提前返回错误，不创建显示器后再尝试移动 sheet。
- 新增 `MacOSSheetFixture.swift` 与 `macos-sheet-smoke.mjs`：自定义 sheet（150 ms 动作回调）、普通/过滤父节点的文件选择 sheet、独立模态文件选择器；检查 AX 根、截图尺寸、根索引、快照/查询/坐标 Cancel、旧查询失效与关闭后父窗口恢复。
- 更新架构、窗口可见性参考、发布记录与 execution plan。

本轮验证：
- Swift 全套 404 项，9 skipped，0 failures；正常签名的独立 release 制品构建成功。
- 实机 native MCP 的 12 组面板矩阵全部通过；Retina 文件面板 1760×896、缩放 300×152、AX-only，根索引 auto/accessibility 均不触发 Cancel，三个显式 Cancel 路径均实际关闭面板，旧 query 索引报错，父窗口恢复。
- main 的负对照返回父窗口；原 PR + main 的负对照点击根节点会误按 Cancel。加入父链检查但未恢复超时时，query Cancel 已关闭面板却返回失败，也已通过回归修复。
- 使用受控临时文件目录，不操作用户文件，不启用全局物理指针，不改变安装或权限；活跃桌面未断言前台/指针稳定性。虚拟显示器停靠未重跑，原作者的验证保留在上文。
- `make check-docs`、Node 语法检查与 `git diff --check` 通过。

已知性能边界：系统的深层临时目录在列视图中带出大量祖先目录内容，默认全树采集超过 30 秒；合并前 main 的独立模态 NSOpenPanel 同样复现，属既有遍历问题。已记入技术债，本轮面板矩阵在短路径受控目录验证，不放宽请求超时或截断树预算。

补充回归：`macos-hit-test-smoke.mjs --descendant-guards --allow-desktop-activity` 通过，覆盖 Retina/缩放/AX-only、空白点、无动作行、窗口根索引及显式 Close。
