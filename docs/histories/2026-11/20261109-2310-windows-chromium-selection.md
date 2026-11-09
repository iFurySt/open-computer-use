## Windows Chromium selection (#162 / #163)

用户要求依次推进 Windows Chromium/Electron 崩溃与 Linux #66；基于贡献者 #163 补充修复。

- 避免 TextPatternRange.GetText 引发无法由 catch 可靠处理的原生访问冲突。
- 原补丁通过 UIA 查询进程主窗口；改为 Win32 窗口类和 PID 校验，无法分类时省略可选选区。补嵌入式 Chromium 的 framework/class 检查，保留密码保护与普通原生选区。
- 增加生产函数的决策测试，以及 Windows WPF 选区和隔离 Edge 本地页面的观察/动作回读回归。
- 原始 Opera/Electron 崩溃来自报告者，本轮不把其他浏览器通过等同于复现该崩溃。Windows Actions 全套通过，真实 WPF 选区、Edge 156 的观察/点击/动作回读通过；Go、PowerShell 分支测试与文档检查通过。

入口与边界：`docs/windows-selected-text.md`。

验证记录：[Windows observation](https://github.com/iFurySt/open-computer-use/actions/runs/42637666877)。#163 已 Squash 合并。
