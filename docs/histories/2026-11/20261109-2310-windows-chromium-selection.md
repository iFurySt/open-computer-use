## Windows Chromium selection (#162 / #163)

用户要求依次推进 Windows Chromium/Electron 崩溃与 Linux #66；基于贡献者 #163 补充修复。

- 避免 TextPatternRange.GetText 引发无法由 catch 可靠处理的原生访问冲突。
- 原补丁通过 UIA 查询进程主窗口；改为 Win32 窗口类和 PID 校验，无法分类时省略可选选区。补嵌入式 Chromium 的 framework/class 检查，保留密码保护与普通原生选区。
- 增加生产函数的决策测试，以及 Windows WPF 选区和隔离 Edge 本地页面的观察/动作回读回归。
- 原始 Opera/Electron 崩溃来自报告者，本轮不把其他浏览器通过等同于复现该崩溃。验证结果在完成后补充。

入口与边界：`docs/windows-selected-text.md`。
