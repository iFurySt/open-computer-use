## [2026-11-08 23:20] | Task: Windows 通过 EnumWindows 解析 UWP app 与模态对话框

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> Windows runtime 用 `Process.MainWindowHandle` 找 app：UWP app 找不到，模态对话框的控件看不到。改成按顶层窗口解析。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`、文档

**Key Actions:**
- **[OCUWin32.TopLevelWindows]**：`EnumWindows` 按 z-order 返回可见顶层窗口的句柄、owner、是否启用、标题和 pid；`ApplicationFrameWindow` 里有 `Windows.UI.Core.CoreWindow` 时报告 CoreWindow 的 pid。
- **[Get-AppWindows / Resolve-App]**：无 owner 的窗口与 `Get-Process` 的进程名组成记录，挑选规则与 `Process.MainWindowHandle` 相同（每个进程最上层的可见无 owner 窗口），只是 UWP 框架改归其 app。匹配顺序改为 pid → 进程名 → 标题精确 → 标题包含，每一步都按 z-order 遍历所有 app 窗口。主窗口被禁用时，取它拥有的、同进程且已启用的最上层窗口（模态对话框）作为根，快照、截图和动作都落在对话框上。
- **[List-Apps]**：用同一份窗口列表，UWP app 以自己的进程列出。
- **[windows-app-resolution.test.ps1]**：窗口列表替身覆盖 UWP 进程名 / 标题、第二个 UWP app、模态对话框（按名称、pid、标题）、主窗口已启用、找不到、`list_apps`。

### 🧠 Design Intent (Why)
`Process.MainWindowHandle` 只认进程自己的顶层窗口：UWP app 的窗口是 ApplicationFrameHost 的框架，`CalculatorApp` 永远找不到；多个 UWP app 共用 ApplicationFrameHost 的一个 `MainWindowTitle`，第二个按标题也找不到。模态对话框是被拥有的窗口，不会成为主窗口，于是“是否保存”对话框的按钮不在快照里，而被禁用的主窗口不接收输入。原来名称和标题在同一轮按进程名排序匹配，标题里含有查询词的其他 app（例如浏览器标签）可能先于同名进程被选中；现在进程名优先。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `scripts/tests/windows-app-resolution.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 同一组替身下，origin/main：`CalculatorApp.exe`、`Settings` 都是 `appNotFound`，`Calculator` 解析成 ApplicationFrameHost，`notepad` 解析成被禁用的主窗口 200，`list_apps` 只列出 ApplicationFrameHost 和 notepad。本分支：CalculatorApp（窗口 90）、SystemSettings（窗口 95）、CalculatorApp、对话框 201，`list_apps` 列出 CalculatorApp、notepad、SystemSettings。新测试在 origin/main 上失败，本分支通过。
- 现有决策测试在 pwsh 7.5 下通过；内联 C# 按 C# 5 编译通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 真实 UWP 框架与 CoreWindow 的关系、模态对话框的 owner / 启用状态，只能在 Windows 桌面上确认；现有 smoke 都按 pid 指定 fixture，fixture 不弹模态对话框，主窗口选择规则与原来相同。

### Maintainer review — 2026-11-13

- 同步 main 并保留挂起探测、动作回读和窗口身份检查。
- PID 查询不回退到标题 / 启动程序；空查询拒绝，标题子串按字面匹配，避免通配符误选应用。
- 沿禁用 owner 的嵌套模态链解析，限制深度、检测循环；对话框关闭后旧 HWND 动作仍拒绝。
- 只有 ApplicationFrameWindow 才解析 CoreWindow 的内容 PID；普通含同名子窗口的宿主不改归属。
- 新发现的边界：跨进程宿主的 posted 按键原本会落到框架，不能保证到达内容。现在明确拒绝 hosted posted 回退；UIA / 显式全局路径保持现有授权规则，type_text 不新增全局回退。
- 新增真实 WinForms 多窗口 / 两层 ShowDialog 测试，以实际按钮计数验证内外层关闭与旧快照拒绝；新增两个原生进程创建真实 frame/core HWND，验证映射、普通窗口负对照与宿主按键拒绝。后者不是打包 UWP 应用，不能写成所有 UWP 已验证。
- 本地 PowerShell 解析 / 分派回归与 Windows 交叉编译通过；完整 Windows 原生结果以该提交的 Windows CI 为准。
- 找不到可操作模态窗口且根窗口仍禁用时，观察可继续，动作明确拒绝，不尝试在禁用 owner 上执行 UIA。
- 真实测试脚手架按 Win32 IsWindowEnabled 读取 ShowDialog 禁用状态（不读 WinForms 缓存属性），原生测试窗口统一 Unicode 注册 / 创建 / DefWindowProc，避免脚手架自身截断标题。
