## [2026-11-08 21:40] | Task: Windows 键盘输入送到有焦点的控件

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> Windows 的 auto `press_key` 把按键投递给顶层窗口、组合键被当成单键；`type_text` 在后台时写进第一个文本框。改成送到有键盘焦点的控件，并拒绝窗口消息带不了的组合键。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`、文档

**Key Actions:**
- **[Get-PostedKeyTarget]**：用 `GetGUIThreadInfo` 取目标窗口线程的焦点控件；在目标窗口内（自身或子窗口）就投递给它，否则仍投递给窗口本身。
- **[Send-Key auto]**：带 `+` 的组合键在发送前拒绝，提示 `key_method=global`；`PostMessage` 失败报错（原来忽略返回值）。`Send-Text` 同样检查投递结果。
- **[Invoke-TypeText]**：焦点是 Edit / RichEdit（含 WinForms 子类）时直接 `EM_REPLACESEL` 写入它，只读（`ES_READONLY`）时拒绝；否则走原来的 UIA 查找，但只在唯一的文本框时选中，多个且都没有焦点时拒绝。
- **[测试]**：新增 `windows-keyboard-focus.test.ps1`；`windows-input.test.ps1` 里 auto `ctrl+a` 原本断言“投递四条消息”，改为断言拒绝、auto `a` 只投递按下 / 抬起。
- **[说明]**：Go 的 server instructions 与 `key_method` 描述、`docs/windows-input.md`、`docs/ARCHITECTURE.md`。

### 🧠 Design Intent (Why)
真实按键由系统交给有键盘焦点的窗口；Win32 edit 的父窗口一般不处理投递来的按键，所以原来对 Notepad 一类窗口发 Return 会报成功但什么也没发生。应用从键盘状态读 Ctrl / Shift，`PostMessage` 不改变键盘状态，投递的 `ctrl+a` 只会被当作 `a` 输入。`type_text` 原来只认 UI Automation 的焦点元素，而它只在前台时属于目标进程，所以后台窗口总是写进树里第一个可写文本框。找不到焦点控件时保持原来的投递目标，避免比原来更少可用。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main.go`
- `scripts/tests/windows-keyboard-focus.test.ps1`
- `scripts/tests/windows-input.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/windows-input.md`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 同一组替身下对照：origin/main 把 Return 投递给顶层窗口 42（焦点在子控件 44）；`ctrl+a` 投递 Ctrl 按下、A 按下 / 抬起、Ctrl 抬起并报成功；焦点在第二个文本框 45 时写进第一个 44；两个都没焦点时写进 44；只读焦点框也写进 44。本分支：投递给 44、拒绝、写进 45、拒绝、拒绝。
- 现有决策测试在 pwsh 7.5 下通过；内联 C# 按 C# 5 编译通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 后台窗口的线程是否报告焦点控件、各 toolkit 是否接受投递给焦点控件的消息，只能在 Windows 桌面上确认。

### Maintainer review

基于最新 main 去掉与 #163 重复的 GetClassName 声明，保留 #166 身份校验。焦点 HWND 验证同进程；UIA 焦点只读时直接拒绝，不吞掉错误后改写其他字段；选定 UIA 控件缺少 HWND 时不另找其他 child。posted key 在按下成功后 finally 释放，补中途异常测试。

增加真实 WinForms 双输入框/独立遮挡窗口回归，经 native MCP 验证已知焦点第二字段键入、选区替换、后台焦点未知时拒绝、Return、拒绝 ctrl+a、无文本焦点且多字段拒绝、只读焦点拒绝。测试接入现有 Windows observation 脚本。

真实 Windows 首轮发现多行 Document 没有 ValuePattern，退到后台后焦点丢失时仍会误写第一个 Edit。改为对全部文本控件计数，不能把不支持写入的 Document/只读字段排除后再猜目标。已知非文本焦点直接拒绝。原 EM_SETSEL 会丢弃选区，改为保留选区并仅执行一次 EM_REPLACESEL，不再失败后用 WM_SETTEXT 重试。
