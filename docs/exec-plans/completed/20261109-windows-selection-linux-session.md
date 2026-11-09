# Windows 选区崩溃与 Linux 会话发现

## 范围与顺序

用户要求继续处理优先级 3–5。第 3 项 #181 已合并；本轮依次处理 #162/#163 与 #66，基于最新 main 修复、独立验证并按既有授权评论和 Squash 合并。

## 约束与风险

- #163：危险 UIA TextPattern 调用可能杀死整个 PowerShell 进程，不能依赖 catch。检测应在调用之前；保留普通原生控件选区、密码保护，不启动用户的浏览器配置。
- 真实 Windows 使用已有 Actions 桌面、临时浏览器 profile 和固定测试页面。区分 contributor 崩溃证据、可控故障注入与本轮实际浏览器结果，不能把未复现的旧版崩溃写成已复现。
- #66：自动发现不得把其他进程的沙盒 bus 地址当成宿主地址。保留显式配置，使用私有 D-Bus/Xvfb/GTK 对照，验证 libatspi 的正常 session-bus fallback。
- 不改变 macOS 行为，不修改系统权限或用户桌面配置。

## 里程碑

- [x] #163：完善原生窗口分类、嵌入式 Chromium 和保守回退；真实 WPF/Edge 与全部 Windows 回归通过，已合并。
- [x] #66：通过真实 /proc 和 GTK 复现旧版环境污染；修复通过相同场景、显式配置与全套 Linux 测试，随本 PR 交付。
- [x] 同步文档、history、发布记录并归档计划。测试使用隔离容器，交付时清理。

## 验证边界

Windows 不宣称独立复现报告者的 Opera/Electron 原生崩溃。Linux 验证真实 GTK 与受控沙盒环境进程，不宣称覆盖完整 Flatpak/GNOME Wayland 部署。
