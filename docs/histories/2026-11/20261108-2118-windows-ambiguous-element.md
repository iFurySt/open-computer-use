## [2026-11-08 21:18] | Task: Windows 动作不再落到另一个同名控件

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> Windows 的 Find-Element 在 RuntimeId 失效后按第一个同名同类型控件动作；改成不唯一就拒绝。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`

**Key Actions:**
- **[Find-Element]**：RuntimeId 仍然优先。失效后要求控件类型、AutomationId、名称同时一致（区分大小写；以 `...` 结尾的名称按 `text_limit` 截断前缀匹配），匹配多于一个时报错并要求重新 `get_app_state`。没有名称和 AutomationId 的记录与原来一样不按身份匹配。整棵树只读一次（原来 RuntimeId 找不到时会再 `FindAll` 一遍）。
- **[windows-element-resolution.test.ps1]**：用 UIA 替身跑生产 `Find-Element`：RuntimeId、唯一控件、两个 OK 按钮、共用 AutomationId 的列表行、被删的行、截断名称、无名控件；接入 Windows CI。

### 🧠 Design Intent (Why)
原来的第二轮匹配是“AutomationId 相同或名称相同，且类型相同”，返回第一个。控件被重建（RuntimeId 变化）后：两个 OK 按钮时点到第一个；列表行共用 AutomationId 时，`b.txt` 行解析成 `a.txt` 行，已被删除的 `c.txt` 也解析成 `a.txt`。截断的长名称则永远匹配不上。宁可拒绝让模型重新观察，也不对另一个控件动作。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `scripts/tests/windows-element-resolution.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 同一测试在 origin/main 的 runtime 上失败（两个 OK 解析到第一个），本分支通过；逐项对照：origin/main 把 `b.txt`、`c.txt` 都解析成 `a.txt`，截断名称找不到；本分支分别是拒绝、`b.txt`、找不到、找到。
- 现有 `windows-observation` / `windows-input` / `windows-set-value` / `windows-tree-budget` / `windows-target` 决策测试在 pwsh 7.5 下通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 真实 UIA provider 在什么情况下换 RuntimeId、以及 PowerShell 5.1 下的运行，只能在 Windows 桌面（本仓库的 windows-observation CI）上确认。

### Maintainer review: final behavior

与 macOS #183 统一为不自动改绑：原 RuntimeId、type、AutomationId 和完整名称摘要均匹配才动作。RuntimeId 失效、名称变更或读取失败要求重新观察。使用 SHA-256 保存完整名称身份，不把 text_limit 的省略号当成任意前缀匹配，也不扩大呈现文本。

真实 WPF fixture 增加改名和原位重建输入框；旧索引 set_value 必须报错且实际文本不变，重新观察后可写。生产函数测试覆盖改名/类型/AutomationId 变化、长名称截断后的变化和无名替代控件。测试接入已有观察脚本，无需另改 workflow。

最终验证：[Windows 全套回归](https://github.com/iFurySt/open-computer-use/actions/runs/42643821852)通过，真实 WPF 改名/重建、Edge、物理输入、大列表与遮挡截图通过；#166 已合并。
