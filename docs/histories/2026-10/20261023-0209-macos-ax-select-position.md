## [2026-10-23 02:09] | Task: macOS 无指针的行选择与 set_position

### 🤖 Execution Context
* **Agent ID**: `claude-code`（subagent）
* **Base Model**: `Claude Opus 5.5 (claude-opus-5-5)`
* **Runtime**: `Claude Code CLI / macOS 本地 worktree`

### 📥 User Query
> 把 fork 上只走辅助功能的 `select` 和 `set_position` 移植到上游：没有 press 动作的列表行（GarageBand 素材库）也能选中；辅助功能允许移动的元素（时间线片段、窗口）移到指定位置并可调整大小，作为需要真实指针的拖拽（#53）的后台替代。上游偏好更少的工具，选更小但仍明确的接口；`set_position` 写前检查可设置、写后回读，避免 #111 评审指出的误报。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`scripts/node-repl`、文档

**Key Actions:**
- **[行选择并入 click]**: 不新增 `select` 工具。element-targeted 左键单击在 press、后代、命中点和 `AXSelectedChildren` 列表选择都未处理时，从元素向上最多 4 层找可设置 `AXSelected` 的 `AXRow` / `AXCell` 并设为 true；cell 接受写入但仍未选中时交给所在行。`auto` 在鼠标事件兜底之前走这一步，`click_method=accessibility` 因此也能选中这类行；坐标点击、双击和 web 区域不变。
- **[set_position]**: 新增 macOS 工具 `set_position(app, element_index, x, y, width?, height?)`。坐标为截图像素，与 `click` / `drag` 相同；写前检查 `AXPosition`（给尺寸时还有 `AXSize`）可设置，不可设置直接报错。先写尺寸再写位置。
- **[回读]**: 每次写入后最多 0.6 s 回读，只比较本次写入的部分。仅当元素仍在原处时报错；应用夹紧或吸附时成功，并以截图像素注明实际落点；读不到时注明未验证。请求与当前位置相同视为成功。
- **[窗口]**: AppKit 会给通过 AX 移动的窗口做约 0.2 s 动画，AX 立即报告新位置，窗口列表随后才更新；移动窗口后等待 0.3 s 再回读，下一次状态的坐标基于新位置。
- **[接口与文档]**: ToolDefinitions、dispatcher、MCP instructions、smoke suite 工具列表、JS `app.setPosition(elementIndex, [x, y], [width, height]?)`、usage / SKILL / js-repl / ARCHITECTURE / QUALITY_SCORE 与 release notes。Linux / Windows 沿用 `select_text`、`query` 的先例，未知工具返回 `unsupportedTool("set_position")`。

### 🧠 Design Intent (Why)
`click` 已经在 `AXList` 上用 `AXSelectedChildren` 选中列表项，表格行的 `AXSelected` 是同一件事的另一种辅助功能形态。放进 `click` 少一个工具，调用方也不用先判断该用哪个工具；`click_method=accessibility` 保证只走辅助功能，工具描述写明了这一点。放在其他 AX 路径之后，行内真正可按的控件仍然优先。

`set_position` 是新能力，无法并入现有工具。坐标用截图像素，与它替代的 `drag` 一致，模型从截图读出的数字可以直接使用。回读按 #111 评审的结论：只有“写入后完全没变”才是静默失败，夹紧和吸附是应用的正常行为。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite/main.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `scripts/node-repl/open-computer-use-repl.test.mjs`
- `skills/open-computer-use/SKILL.md`
- `skills/open-computer-use/references/usage.md`
- `docs/references/js-repl.md`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- Swift 384 项测试通过（7 项跳过，0 失败），新增回读语义与参数校验两项，工具清单与 schema 断言同步；Node REPL 32 项通过；`make check-docs` 通过。
- 真机，用一个临时 AppKit 探针（accessory 应用，从不激活，窗口排在所有窗口之后）：5 行无 press 动作的 view-based `NSTableView`（行的 `AXSelected` 可设置），以及三个 `AXPosition` / `AXSize` 可设置的布局项：自由移动、按 20 pt 网格吸附、接受写入但忽略。in-process CLI，关闭软件光标；每轮前后前台应用和指针位置不变，探针退出后无残留窗口。
- 行选择：main 上 `click_method=accessibility` 点行返回 `could not click element_index=6`，`auto` 只发出鼠标事件，探针选中为空。本改动下 `auto` 点 Sound 4 后选中 [4]，再点 Sound 3 变为 [3]（替换选择，与点击一致），`accessibility` 点行同样选中。
- set_position：自由片段移到请求的截图点，探针记录的落点与请求一致，无附注；吸附片段返回成功并注明 `x=620, y=364`（请求 626, 374）；同时给尺寸时先变为 150×60 pt 再定位；窗口（元素 0）移动 (40, 20) px 即 (20, 10) pt；忽略写入的片段 0.6 s 后报错 `is still at ...`；行（位置不可设置）写前即拒绝；`include_screenshot=false` 后与坐标点击一样拒绝。main 上该工具为 `unsupportedTool("set_position")`。
- 发现：AppKit 以动画移动窗口，未等待时下一次状态的窗口坐标是旧的（错误信息中的坐标偏了 (40, 20) px）；加 0.3 s 等待后正确。
- 另一个与本改动无关的现有问题：点击路径的命中测试把窗口点当作截图像素再换算（`hitTestElement`），2x 截图下命中位置减半。探针里 `auto` 点 Sound 1 时命中到表头按钮并按下了它，行未选中；单独处理，不在本次范围。
