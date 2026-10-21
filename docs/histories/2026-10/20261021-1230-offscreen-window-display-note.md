## [2026-10-21 12:30] | Task: 离屏窗口快照增加 display note

### Execution Context

- Agent ID: `lead`
- Base Model: deepseek-flash
- Runtime: DSH web

### User Query

> 从 #69 关闭后仍缺的 4 项行为里挑最小、最自包含的一项做成小 PR（本地分支，不 push、不开 PR），先核实缺口并给出代码证据。

### Gap Triage（当前 main `43eb4b5`）

| 缺口 | 状态 |
| --- | --- |
| 1. 目标窗口在所有活动屏幕之外时的 `--- display note ---` | 缺失。`renderedText` 只输出 App/Window/tree，没有屏幕相交检查（`AccessibilitySnapshot.swift` 的 `renderedText`）；全仓无 `display note` 或 `CGGetActiveDisplayList`。 |
| 2. 弹层快照共存（popup 标记） | 缺失。快照只选一个目标窗口（`preferredWindowCaptureCandidate` 返回单个 candidate），没有 popup 标记或共存逻辑。 |
| 3. 弹层遮挡下的稳定元素选择器 | 部分替代。仅 `perform_secondary_action` 的 action selector（`meaningfulActions`/`secondaryActionDisplayName`）与 `query` 的 text/role + `window_id` 重新校验；没有元素级 selector。 |
| 4. AX 动作前把目标滚入视口 | 缺失。`AXScrollToVisible` 只出现在 `meaningfulRawActions` 的忽略列表（`AccessibilitySnapshot.swift:2007`），从未被主动执行；全仓无 `ensureElementVisible`/`OPEN_COMPUTER_USE_SCROLL_TARGET_INTO_VIEW`。 |

选缺口 1：纯增量文本，不改变任何动作语义，可用纯函数单测；缺口 4 需要在 click/set_value/select_text 路径上自动滚动并回读 frame，默认开启会改变既有行为，关闭则价值有限，审计和风险都更大。

### Changes Overview

- 新增 `WindowDisplayNote.swift`：`windowDisplayNote(windowBounds:activeDisplayBounds:)` 纯函数与 `activeDisplayBounds()`（`CGGetActiveDisplayList` + `CGDisplayBounds`，与 `CGWindowList` 同为 Quartz 全局坐标）。
- `AppSnapshot` 新增 `displayNote` 字段，`renderedText` 在 `Window:` 行之后输出该 note；`SnapshotBuilder.build` 计算一次并传入两条快照构造路径（含 `include_ax=false`），query 索引动作的 lite snapshot 也带上。
- note 内容为 `--- display note ---` 加窗口 frame 与处理建议；窗口与任一活动屏幕相交、bounds 为空或活动屏幕列表不可用时返回 nil，既有快照文本不变。
- `skills/open-computer-use/references/usage.md` 补充说明。

### Design Intent

离屏窗口常常只能从 AX 拿到窗口 chrome，agent 会误判为应用没有内容。用纯几何判断（窗口 frame 与活动屏幕 frame 相交）实现，不依赖窗口是否真的 off-screen；文本只解释状态与建议，不触发激活、恢复或移动窗口。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/WindowDisplayNote.swift`（新增）
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/WindowDisplayNoteTests.swift`（新增）
- `skills/open-computer-use/references/usage.md`

### Validation

- `swift build` 成功。
- `swift test`：388 个测试，7 个跳过，0 失败；新增 `WindowDisplayNoteTests` 6 个用例覆盖窗口在屏内/跨屏/完全离屏/缺 bounds/空屏幕列表/渲染插入顺序。
- `make check-docs` 通过。
- 变更只在本地分支 `fix/offscreen-window-display-note`，未 push、未开 PR。
