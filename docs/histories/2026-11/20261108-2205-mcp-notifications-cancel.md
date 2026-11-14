## [2026-11-08 22:05] | Task: MCP 通知不再应答，支持 notifications/cancelled

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> macOS MCP server 会应答没有 id 的通知，也不处理 `notifications/cancelled`；改成符合 JSON-RPC / MCP。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`、`apps/OpenComputerUse`

**Key Actions:**
- **[通知]**：`StdioMCPServer.handle(line:)` 对没有 id 的消息一律不应答，`notifications/turn-ended` 照旧结束会话。
- **[MCPStdinRequests]**：stdin 在独立线程读取，请求仍按顺序逐个处理；还没开始的请求被取消后不再执行，正在执行的请求跑完但丢弃应答。
- **[app agent 代理]**：`proxyMCP` 用同一个读取器，默认的代理路径同样生效。

### 🧠 Design Intent (Why)
main 上每条 `notifications/cancelled` 都收到一条 `id: null` 的 "Method not found" 错误；读取与执行在同一线程，调用进行中读不到取消，被取消的排队请求照样执行并应答。JSON-RPC 规定通知不应答，MCP 要求不应答被取消的请求。正在执行的动作无法中途安全停止，所以只丢弃其应答。

### ✅ Validation
- 真实 `open-computer-use mcp`（关闭代理）脚本：initialize、未知 id 的取消、`list_apps` 2 和 3 并取消 3、执行中的 `list_apps` 4 再取消、ping 5。main：3 条取消各收到一条错误，3 和 4 都有应答；修复后只有 1、2、5 有应答。
- 新增单测：通知不应答；排队请求被取消后不执行、执行中被取消的请求应答被丢弃。
- `macos-request-lifecycle-smoke.mjs` 内存与空闲唤醒检查通过；末尾 buildIdentifier 断言需要打包签名的 app，main 上同样失败。
- `swift test`：455 项，8 跳过，0 失败。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/MacOSAppAgentProxy.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
