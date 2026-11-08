## [2026-11-08 22:25] | Task: Windows 对管理员窗口的输入改为拒绝

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> 目标 app 以管理员身份运行时，Windows runtime 的输入被系统丢弃却报告成功；改成在发送前拒绝。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`、文档

**Key Actions:**
- **[OCUWin32.IntegrityLevel]**：`PROCESS_QUERY_LIMITED_INFORMATION` + `TokenIntegrityLevel` 读进程的强制完整性级别，读不到返回 -1。
- **[Assert-InputAllowed]**：动作类工具在定位元素、发送任何输入之前比较目标进程与 bridge 自身的级别，目标更高就报错并说明怎么办；任一方读不到时不拒绝。`get_app_state` / `list_apps` 不检查。
- **[windows-elevated-target.test.ps1]**：取出生产 dispatch 直接运行，覆盖更高 / 相同 / 双方都高 / 更低 / 读不到 / 只读观察。

### 🧠 Design Intent (Why)
UIPI 会丢弃从低完整性级别发往高级别窗口的消息和 SendInput；SendInput 不会通过返回值表明被丢弃，按键与文字路径也忽略 `PostMessage` 的返回值，于是对管理员窗口的 `press_key`、`type_text`、`key_method=global` 都报成功。UI Automation 也只能看到这类窗口的外框，元素动作退化成同样被丢弃的消息。发送前拒绝能给出原因和办法。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `scripts/tests/windows-elevated-target.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/windows-input.md`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 用同一组替身运行 origin/main 的 dispatch：对级别 0x3000 的目标从 0x2000 发 `press_key`，返回 `ok: true` 且按键已投递；本分支在投递前拒绝。新测试在 origin/main 上失败（没有该检查），本分支通过。
- 现有决策测试在 pwsh 7.5 下通过；内联 C# 按 C# 5 编译通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 真实的管理员窗口、以及中完整性级别能否读到它的 token，只能在 Windows 桌面上确认；GitHub 的 Windows runner 本身以管理员运行，现有 smoke 的 fixture 与 runtime 同级，不受影响。
