## [2026-10-23 05:35] | Task: type_text 输入到当前焦点，并替换选中文本

### Execution Context

- Agent ID: `Claude Code`
- Base Model: Claude Opus 5.5
- Runtime: Claude Code CLI / macOS arm64

### User Query

> 把 fork 端到端运行中发现的 type_text 问题中通用的部分提交到上游：文字要进当前有焦点的元素，有选区时要替换选区。

### Changes Overview

- `typeText` 先读应用当前的 `AXFocusedUIElement`，读不到才用快照里的 `focusedElement`。快照是上一次读取时的焦点；之后的按键（⌘S 弹出保存面板、⌘L）会移走焦点，原来文字会写进面板下面的文档。
- `typeTextBySettingFocusedValueIfAvailable` 在有选区、或插入点不在末尾时，设置 `kAXSelectedTextAttribute`，像真实按键一样替换选区 / 在插入点插入；否则仍是原来的 base value + text。原来 ⌘A 后输入会把文字追加到全文末尾。
- 两个辅助函数改为接收元素而不是快照。

### Design Intent

不改键盘回退路径，只改选哪个元素、以及 AX 设值时写到哪里。`kAXSelectedTextAttribute` 不可设或设置失败时回到原逻辑，占位符处理不变。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`

### Validation

- 一个从不激活、窗口在最底层的 AppKit 探针（`NSTextView` 内容 "hello world" 选中 "hello" 并持有焦点，另有一个 `NSTextField`；收到 SIGUSR1 时焦点移到 field）。进程内 `mcp`：`get_app_state` → `type_text "X"` → 发 SIGUSR1 → `type_text "Y"`：
  - origin/main：text view "hello worldX"，然后 "hello worldXY"，field 为空。
  - 本分支：text view "X world"，field "Y"，text view 不变。
  - 两次前台应用均未改变。
- fork 端到端运行中在 TextEdit 验证：⌘A 后输入 X 得到 "X"；Left 后输入 < 插入在插入点。
- `swift test`（跳过 `CursorWindowFollowTests`）：374 项，7 项跳过，0 失败。
