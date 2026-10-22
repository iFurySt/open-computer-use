## [2026-10-23 02:45] | Task: 修复坐标点击空白处会按下窗口里别处的按钮

### Execution Context

- Agent ID: Claude Code subagent（Agent tool 派发）
- Base Model: Claude Opus 5.5
- Runtime: Claude Code CLI，macOS

### User Query

> 坐标点击（`click` 传 x/y，`click_method` 为 `auto`）点到没有可操作元素的空白处时，会按下窗口里别处无关的按钮。追到根因并做最小修复：坐标点击只作用于 frame 包含点击点的元素或命中元素的祖先，绝不按下窗口里别处的子孙，也不按窗口控制按钮；点击点处没有可操作元素时，落到现有的 pid 定向鼠标事件。顺带检查 element_index 点击路径，只在它会按下目标 frame 之外的元素时修复。附回归检查。

### Changes Overview

**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **根因**：坐标点击的 `clickCandidates` 先取 `bestElement(containing:)`。点在空白处时它是窗口记录（窗口有 `AXRaise`，`clickPriority` 排第一）。`performAXClickSequence` 对窗口本身做不了 `AXPress`，于是扫描窗口的全部子孙（`descendantClickCandidates`，按优先级和面积排序，与点击点无关），按下最小的那个可按元素，常常就是关闭按钮。
- **修复**：新增纯函数 `isDescendantClickCandidateAtTarget`，`performAXClickSequence` 的两处子孙扫描都经过它：坐标点击时子孙 frame 必须包含点击点；element_index 点击时子孙 frame 必须与目标的 click frame 重叠；没有 frame 的子孙不按。坐标点击把窗口点传进 `performAXClickSequence(clickPoint:)`。
- **element_index 路径**：就近命中回退会扫描命中元素的子孙；命中元素可能是窗口或大容器（frame 为空时 `shouldScanDescendantsOfHitRecord` 直接放行），所以也能按到目标之外。现在同样限制在目标 click frame 内；按下目标自己或其行内的子孙不受影响。
- 就近命中回退里重复计算的 `clickFrame(for:)` 复用同一个值。
- 补单元测试，并在 `docs/ARCHITECTURE.md` 写明这条规则。

### Design Intent (Why)

人点空白处什么也不会按下；坐标点击应该同样只作用于点下去的位置。问题出在子孙扫描不知道点击点，所以把约束放在扫描结果的唯一出口上，一处同时覆盖坐标点击、element_index 点击和就近命中回退三条路径。命中元素本身（AX hit-test 的结果）和祖先（列表选择、Electron 行级祖先）本来就在点击点上，保持不变。

与修复 `hitTestElement` 坐标空间的 #126 相互独立：本修复不改命中测试；没有 #126 时 2x 屏幕上的命中测试仍会探测错误位置，其结果作为候选仍可能按到旁边的控件，两者都合入后才完全干净。两边都在 `feature-release-notes.md` 表头后插入一行，合并时会有一个容易解决的文本冲突。

### Validation

- 新建一个不激活、位于所有窗口之后的 AppKit 探针：窗口有可用的关闭按钮、角落里一个小按钮、一个普通按钮和一块空白，并在 app 收到 mouseDown 时记录落点。CLI 在进程内运行（`OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1`、`OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS=1`）。
  - 修复前：坐标点击空白处 (300,180)，候选为窗口，"handled by descendant" 按下 16x16 的关闭按钮，探针窗口被关闭，回读报 `cgWindowNotFound`。
  - 修复后：不按任何子孙，探针收到落在 (300,180) 的 mouseDown；窗口仍在。
  - 修复前后一致：坐标点击和 element_index 点击普通按钮都会按下它。
- 已有探针：MarksProbe 修复前按下一个 0x0 的 AXButton，修复后不再按；AXSelectProbe 修复前按下（禁用的）关闭按钮，修复后不再按，但在没有 #126 时命中测试仍会按下列表头，叠加 #126 后什么也不按。
- 遗留：element_index 直接点窗口记录本身时，关闭按钮在窗口 frame 内，仍会被子孙扫描按下（修复前后相同），不在本次范围内。
- `swift test` 全量通过（384 项，7 项跳过）。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`
