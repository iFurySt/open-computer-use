## [2026-10-23 01:11] | Task: Resolve relative call files before proxying

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 逐条核对 #83 在当前 main 上是否仍能复现，对仍存在、修法清楚的问题做最小修复。

### 🛠 Changes Overview
**Scope:** macOS CLI（app-agent proxy）

**Key Actions:**
- **转发前解析相对路径**: CLI 把 `call` 转发给 app agent 前，按调用方当前目录把 `--args-file` / `--calls-file` 的相对路径转成绝对路径；绝对路径保持不变。
- **回归覆盖**: 新增测试，在临时目录写入 `calls.json`，验证转换后的参数仍能被解析并读到文件。

### 🧠 Design Intent (Why)
macOS 上 `call` 由 LaunchServices 启动的 app agent 执行，agent 的工作目录不是调用方的目录，所以 `--calls-file calls.json` 在 agent 里按 `/` 解析，报 `Unable to read JSON file calls.json`，README 里 `--calls-file examples/...` 的示例同样失败。修复放在 proxy 发送参数的唯一入口，agent 端和 Linux / Windows 的进程内路径不受影响。失败时的报错现在带上解析后的绝对路径，便于定位。

验证：新测试在修复前失败（复现同一报错），修复后通过；用 debug App 从临时目录运行 `call --calls-file calls.json` 与 `call list_apps --args-file args.json`，修复前失败、修复后成功。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseCLI.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/MacOSAppAgentProxy.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
