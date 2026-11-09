## [2026-11-08 22:05] | Task: Windows 动作送达后读取失败不再报成动作失败

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> Windows runtime 在动作之后读取窗口失败时整次调用报错，模型会以为动作没做成而重试。把“已送达”和“之后的观察失败”分开报告。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`、文档

**Key Actions:**
- **[runtime.ps1 dispatch]**：动作执行完后的 `Build-Snapshot` 单独 try；失败时返回 `ok: true` 和 `observationError`，动作本身的错误仍然是 `ok: false`。
- **[main.go]**：`psResponse.ObservationError`；动作结果为非错误文本，写明动作已送达、读取失败的原因、下一步先 `get_app_state`，并删除该 app（及同 pid 别名）的旧快照，旧索引不能再用。动作类工具 30 s 超时的错误也说明动作可能已经送达。
- **[测试]**：`windows-action-observation.test.ps1` 从 runtime 里取出生产 dispatch（顶层 try/catch）直接运行；Go 侧 `TestDeliveredActionWithFailedObservationIsNotAnError`。

### 🧠 Design Intent (Why)
动作和动作后的快照在同一个 try 里，快照抛错（点击关闭了窗口、主窗口句柄在重建时暂时为 0、元素树读取中途窗口销毁）就变成整次调用失败。动作其实已经发出，模型按失败处理会重复点击或重复输入。只读的 `get_app_state` 失败仍然是错误。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/input_review_test.go`
- `scripts/tests/windows-action-observation.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 同一测试在 origin/main 的 runtime 上失败：按键已发出后快照抛 `appNotFound`，返回 `{"ok":false,"error":"appNotFound(\"fixture\") ..."}`；本分支返回 `ok: true` 加 `observationError`。
- 现有决策测试在 pwsh 7.5 下通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 真实应用里哪些动作之后读取会失败（关闭窗口、窗口重建），只能在 Windows 桌面上确认。

### Maintainer review

合并最新 main。补 bridge 超时/通信错误/缺少响应或快照时清除同进程所有缓存别名；超时只说明结果未知，不声称一定送达。显式观察失败继续返回错误。真实 WPF fixture 增加关闭按钮，native MCP 点击后通过接收端标记和进程退出验证送达，检查回读警告和旧索引拒绝。测试接入现有 observation 入口。

真实 WPF 关闭测试与 WinForms 输入回归已通过。整套物理输入回归另暴露测试命令文件原地写入的竞态：fixture 可能读到不完整 JSON，后续命令成功后仍保留旧错误。测试命令改为原子发布，成功执行清除旧错误，失败输出具体原因。

维护者最终验证：完整 [Windows observation](https://github.com/iFurySt/open-computer-use/actions/runs/42649522891) 通过，含真实 WPF 关闭/旧索引拒绝、WinForms 焦点输入、物理键鼠、预算、遮挡截图与原始版本对照。#171 已 Squash 合并。
