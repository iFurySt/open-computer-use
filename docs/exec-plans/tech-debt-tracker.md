# 技术债追踪

这里记录那些暂时不阻塞当前任务、但已经值得留档的技术债。

| 日期 | 区域 | 债务描述 | 为什么会存在 | 计划中的后续动作 |
| --- | --- | --- | --- | --- |
| 2026-10-31 | 跨平台文本选区 | Linux 的 EditableText 路径仍在全文末尾插入；Windows 显式启用的 UIA ValuePattern 回退仍拼接当前值与输入。 | #130 修复的是 macOS AX 输入；代码审查发现另两条旧路径尚未统一，未在本轮改动或实测。 | 独立补实时焦点、选区替换、失败不重发及真实 GTK/WPF 回归，保留 Windows 默认禁用 UIA 文本回退的边界。 |
| 2026-10-31 | macOS 文件选择器遍历 | NSOpenPanel 列视图会暴露上层目录；较深的系统临时目录中，默认全树采集可能超过 native MCP 的 30 秒请求预算。 | #118 实测栈停留在逐节点 AX 读取和 visibleRows；合并前 main 的独立模态面板也复现超时。受控短路径目录的 12 组面板测试通过。 | 评审 AX 批读优化时补大目录回归，约束实际访问节点和耗时；不要仅增大超时。窄目标可先用 query。 |
| 2026-10-17 | 重复截图 | 请求截图时仍会返回未变化的画面。 | #101 已统一三个平台的显式采集开关；相同图像省略是独立能力。 | 评估按会话 / 应用 / 窗口隔离的精确图像去重；首帧、重置与强制返回必须明确，不能用 AX 未变推断画面未变，也不把去重当成跳过截图采集。 |
| 2026-04-17 | 普通 app AX snapshot | Finder 路径已经能拿到前台窗口子树并输出 window-relative frame，但当前还缺更多真实 app 回归样本，无法证明这套 rooting / traversal 对复杂 app 都稳定。 | 这一轮先把 Finder 这类真实 app 的坐标换算和窗口子树收敛好，再把 deterministic 回归继续留给 fixture。 | 增加 Safari / System Settings / Activity Monitor 等真实 app 样本验证，并继续收敛 `kAXMainWindowAttribute`、focused element parent chain 和多窗口回退策略。 |
