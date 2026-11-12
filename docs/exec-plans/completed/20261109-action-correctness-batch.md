# 操作正确性与基础 CI 收尾

用户授权按五组依次修复、实测、推送并评论 `LGTM. Thanks!` 后 Squash 合并，不发版。

## 顺序与验收

- [x] #173：自有鼠标按下配对释放；会话撤销、按下前失败与真实事件队列回归。
- [x] #180 / #179：Linux 输入框点击不提交、只读拒绝；隔离 GTK/Qt 实测。
- [x] #183 / #166：跨平台旧索引身份核对；歧义拒绝，真实可变控件回归。
- [x] #169 / #171：Windows 焦点控件键入与动作/回读错误分离；真实 WPF/WinForms。
- [x] #165：恢复 clean-checkout 通用 CI；Linux 与 macOS 检查、GitHub CI。

## 约束

每个 PR 基于最新 main，保留贡献者提交，修复和验证结果同步到既有 history。真实测试使用临时 fixture / 隔离桌面，不操作用户数据。不把模拟测试说成真实平台验证，不为测试取消系统安全边界。Windows 使用已有 Actions 桌面；Linux 使用私有 D-Bus/Xvfb。每项通过后合并，再继续下一项。

## 完成记录

- #173：实际 AppKit 事件队列验证配对释放；Swift 461 项、9 项环境跳过，无失败。
- #180 / #179：隔离真实 GTK 3/Qt 6 对照确认旧版本错误提交/改写只读值，修复版本拒绝或正确聚焦；Go 与 Python 通过。
- #183 / #166：macOS 真实控件改名、重复输入和面板回归；Windows 真实 WPF 改名/重建拒绝、重新观察恢复。[Windows 验证](https://github.com/iFurySt/open-computer-use/actions/runs/42643821852)。
- #169：真实 WinForms 测试发现多行 Document 无 ValuePattern 导致误选首字段，补全计数与选区保留；[最终 Windows 验证](https://github.com/iFurySt/open-computer-use/actions/runs/42646920550) 通过。
- #171：实际 WPF 关闭按钮、进程退出、回读警告与旧索引拒绝；[完整 Windows 验证](https://github.com/iFurySt/open-computer-use/actions/runs/42649522891) 通过。补超时/通信错误的同进程别名失效和测试命令原子更新。
- #165：干净 main 复现卫生检查和误启动 native；修复后 macOS、非 root Linux 完整 ci.sh 及 [GitHub CI](https://github.com/iFurySt/open-computer-use/actions/runs/42650670909) 通过。

前七个 PR 已按授权评论并 Squash 合并；本计划随最后的 #165 合并归档。不发版。各平台验证只覆盖记录的实际 fixture / 场景，不代表所有第三方应用。
