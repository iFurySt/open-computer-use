## [2026-10-23 02:00] | Task: macOS 新增 read_clipboard / write_clipboard

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS`

### 📥 User Query
> 把队友在 fork 中实现的剪贴板读写移植到上游：程序读回自己复制的文字，但不返回带 concealed / transient / auto-generated 标记（nspasteboard.org，密码管理器会设置）的条目；也能把准备好的文字放到剪贴板。对应 #83 第 6d 条对剪贴板工具的需求。安全是主要评审风险：保留过滤、仅限文本、限制大小，并与其他动作一样受 Locked Use 会话检查约束。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`scripts/node-repl`、`apps/OpenComputerUseSmokeSuite`、文档

**Key Actions:**
- **[工具面]**: 按 `query` / `select_text` 的方式新增 `read_clipboard`（无参数，read-only annotation）和 `write_clipboard`（`text`），加入 `ToolDefinitions`、dispatcher、MCP instructions 的工具列表和 smoke suite 的工具清单；native surface 从 11 个变为 13 个。
- **[读取过滤]**: 先检查 pasteboard 的 `types`（覆盖所有 item），带三种标记之一时直接报错，不请求文字内容。非文本、空文本、超过 100000 UTF-16 code units 的文本都返回错误；macOS 15.4+ 上系统设置拒绝剪贴板访问时如实报告，不误报为“没有文字”。
- **[写入]**: `clearContents` 后写入纯文本，写入失败时报错，成功返回 `ok`。
- **[会话检查]**: 两个工具在访问剪贴板前调用 `requireUsableComputerUseSession()`。它们在 `ToolDefinitions` 中，app agent 因此把它们放进 Locked Use 的 `lockedUse.perform` 范围，与其他动作共用同一个租约检查；锁屏无租约时拒绝。
- **[JS]**: 新增 `cua.readClipboard()` / `cua.writeClipboard(text)`，非字符串或空文本在调用 native 前拒绝。
- **[Linux / Windows]**: 不实现，与 `query` / `select_text` 相同，调用时返回既有的 `unsupportedTool("…")` 错误，并在文档中说明。

### 🧠 Design Intent (Why)
有些应用的文字不在 AX tree 中（例如画布绘制的文档），复制后读剪贴板是 Agent 拿到这些文字的唯一途径；粘贴准备好的文字也比逐字输入更可靠。剪贴板可能含有用户的敏感内容，所以读取只返回纯文本、跳过密码管理器标记过的条目且不读取其内容，并限制单次大小。用失败而不是空字符串表示“没有可返回的文字”，Agent 不会把错误信息误当成剪贴板内容。

`write_clipboard` 会覆盖用户复制的内容，工具说明与 MCP instructions 一致，要求仅在用户要求时使用。

原始实现是 fork 中 dispatcher 里的 18 行（kushagra2503）；本次保留其标记过滤逻辑，补齐了工具定义、会话检查、大小限制、错误语义、JS API、测试和文档。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ClipboardTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LockedUseDispatchTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite/main.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `scripts/node-repl/open-computer-use-repl.test.mjs`
- `skills/open-computer-use/SKILL.md`
- `skills/open-computer-use/references/usage.md`
- `docs/references/js-repl.md`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
- `docs/SECURITY.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 单元测试全部使用私有命名 pasteboard（`NSPasteboard(name:)`），不读写用户的通用剪贴板：纯文本与 Unicode 读回；三种标记逐一拒绝且错误中不含条目文字；多 item 中任一 item 带标记即拒绝；非文本 / 空文本报错；恰好 100000 与 100001 个 code unit 的边界；写入覆盖带标记的条目后读回。
- 撤销租约的 validator 下，两个工具都在访问 pasteboard 前抛出，私有 pasteboard 内容不变。去掉过滤或会话检查后，对应测试失败。
- 工具数量 / 名称、描述与 annotation、MCP instructions 测试通过；Node REPL 32 项测试通过（Persistent / Worker 两种 session）。
