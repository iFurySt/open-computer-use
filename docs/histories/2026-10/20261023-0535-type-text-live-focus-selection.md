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


### 2026-10-31：合并前复核与补修

- 合并最新 main（含 #118），保留原贡献者提交。
- 删除当前焦点读取失败时的缓存回退；写入前再次核对同一焦点与可用会话，读取用应用对象的局部超时，不修改全局 AX 超时。
- AXSelectedText 可写时直接替换选区，不再要求 AXValue 同时可写，也覆盖末尾插入。
- 不支持 AXSelectedText 时，在全文和有效选区可读、AXValue 与选区均可写的条件下，核对内容未变，再按 UTF-16 范围替换并恢复光标。拒绝越界、负数和拆开的代理对，保留组合字符与空白。
- 已尝试的写入失败直接返回错误；全文已写入但恢复光标失败也明确报告，绝不再追加或换键盘路径重复发送。其余仅支持键盘的可编辑目标仍走既有进程定向路径，交付效果依赖应用。
- 原生 MCP/CLI 的空文本继续被参数校验拒绝；直接调用 service 的空字符串不删除选区。
- 新增 AppKit 文本输入 fixture 和 native MCP/Worker JS/CLI smoke。真实 NSTextField 与 sheet 验证焦点变化；NSTextView 的 AX 属性桥接注入不可写、拒绝写入与检查期间焦点变化，实际文本和写入次数由独立进程记录。
- 同步架构、发布记录和执行计划。代码审查发现 Linux / Windows 可选 UIA 路径的相似追加逻辑，另记跨平台技术债，不将 macOS 验证推广到其他平台。

验证：真实输入 smoke 全部通过，包括中文/emoji、连续输入、只可写 SelectedText、按范围写 Value、选区/全文/光标写入失败、实时焦点缺失/切换、CLI 与 Worker JS。Swift 全套 406 项（9 skipped）通过；main 负对照得到 hello worldX，原 PR 负对照在不可读焦点下仍将旧控件写成 WRONG world。Node 语法、make check-docs 和 git diff --check 通过。

限制：不改变 sky_key；未覆盖所有第三方富文本编辑器或键盘事件的后台接收能力；活跃桌面不声称前台/物理指针完全不变。测试使用独立正常签名制品和现有权限，不操作用户文档。
