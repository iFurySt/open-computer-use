## [2026-11-08 22:40] | Task: Windows 无响应窗口快速失败

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> 目标 app 卡住（UI 线程不再处理消息）时，Windows runtime 的每次调用都等到 30 s 超时才返回笼统错误；改成在 UI Automation 调用前探测并快速报告。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`、文档

**Key Actions:**
- **[OCUWin32.IsHung]**：`IsWindow` 之后先看 `IsHungAppWindow`，再发 `SendMessageTimeout(WM_NULL, SMTO_ABORTIFHUNG, 1000)`；句柄已经不是窗口时不算挂起。
- **[Assert-WindowResponds]**：连续两次挂起才报 “<app> is not responding”，只忙一下的窗口第二次就能通过，正常窗口只探测一次。
- **[调用点]**：`Get-MainElement` 在 `FromHandle` 之前（`get_app_state`、元素定位、动作后的快照都经过它）；dispatch 在执行动作、发送任何输入之前。
- **[windows-hung-window.test.ps1]**：替身覆盖挂起、忙一次、正常三种窗口，以及 dispatch 不向挂起窗口发键。

### 🧠 Design Intent (Why)
UI 线程不处理消息的窗口会让对它的 UI Automation 调用和 `SendMessage` 一直等下去，bridge 只能靠 Go 侧 30 s 超时结束，返回 “Windows runtime timed out after 30s”，模型无从知道是 app 卡住。投递给挂起窗口的消息会留在队列里，等 app 恢复后才执行，时间点不可控，所以动作也在发送前拒绝。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `scripts/tests/windows-hung-window.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 同一组替身下，origin/main 对挂起窗口直接 `FromHandle`（UIA 读取 1 次），`press_key` 投递按键并返回 `ok: true`；本分支两次探测后拒绝，UIA 读取 0 次，按键 0 次。新测试在 origin/main 上失败，本分支通过。
- 现有决策测试在 pwsh 7.5 下通过；内联 C# 按 C# 5 编译通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 真实挂起窗口下的耗时（UI Automation 等多久、探测是否在约 2 s 内返回）只能在 Windows 桌面上确认。

## Maintainer review — 2026-11-13

Distinguish probe timeouts from Win32 failures such as access denied; a failed probe still refuses the operation, but is not mislabeled as a hung app. Request `SMTO_ERRORONEXIT` and clear/read the native last error explicitly.

Added a Windows-only Go integration test. An owned WinForms fixture stops its real UI message pump until a file signal resumes it. Production `runPowerShell` must refuse observation and input well before its 30-second timeout; after recovery the fixture must have received zero queued keys, then accept exactly one positive-control key. Tests never send input to user applications. The existing Windows workflow runs it with `go test ./...`; cross-compilation on macOS is only a build check. Results are recorded on PR #174.
