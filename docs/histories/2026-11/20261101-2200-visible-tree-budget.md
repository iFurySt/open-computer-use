# 控件树预算优先保留可见操作

用户要求修复大目录耗尽节点预算、遗漏操作按钮的问题，同时检查 Windows/Linux，真实测试后按既有流程提交合并。

- 三平台改为有界优先选择，再按原树序输出；保留真实元素/原路径与连续索引。集合不能先耗尽所有额度，候选扫描、输出节点、深度和循环均有约束，截断有明确提示。
- macOS 优先使用集合 AXVisibleChildren，避免完整内容被合并回来；按窗口/滚动区域判断离屏，重复引用只渲染一次，集合摘要显示实际纳入数量。
- Windows 使用 UIA IsOffscreen、控件角色和集合分支优先级；原来绑定 DFS 实现文本的 Go 断言由执行生产函数的 PowerShell 行为测试取代。
- Linux 使用 SHOWING 加滚动区域几何。真实 GTK 测试发现离屏单元仍返回 SHOWING=true，但提供离屏哨兵坐标；补回归后滚动末行可以优先返回。
- 默认 1200 节点不变，无新配置；新增三平台真实 fixture/smoke、边界单测和 Windows CI 步骤。说明见 docs/tree-budget.md。

## 验证进度

- macOS 2000 文件 NSOpenPanel：1200/40 节点下保留操作按钮，索引 Cancel 确实关闭面板；旧 main 在 40 节点下缺 Cancel。普通 300 控件完整 AX 输出与 main 一致，真实点击及下一轮状态通过。
- Linux 私有容器 Xvfb/D-Bus + GTK/AT-SPI：2000 行、1200/40 预算、真实底部点击及滚动末行通过。Python 39 项通过；Go 在 Linux 环境通过。
- Windows 真实 WPF/UIA 2000 项、1200/40 预算、索引点击和滚动末行通过；现有观察、滚轮、DPI 和物理输入回归通过。快照分别约 9.3 秒 / 5.4 秒（CI 样本，非稳定基准）。[CI 结果](https://github.com/iFurySt/open-computer-use/actions/runs/41317675590)。

- 补重复/无效候选的预算计数和深度边界回归；Windows WPF 状态文件改用明确的备份路径，兼容 Windows PowerShell 5.1 的 File.Replace 参数转换。

- Windows 真实 2000 项 WPF 测试发现逐项 UIA 读取仍超出既有 30 秒超时，补本轮 snapshot 的 CacheRequest 属性批读，动作仍重新解析目标。保持原有超时，上述真实 CI 已通过。

- Node 54 项、Swift 排除需解锁的 TextSelectionOperationTests 后 414 项（11 跳过）、新 AX 语义回归 10 项通过。完整 Swift 锁屏运行中，文本选择的会话校验和真实窗口用例失败；需正常解锁后复测，不修改安全策略绕过。
- macOS 早期已解锁实测通过；最终候选边界修订后的签名程序已构建，但真实 NSOpenPanel / 12 组面板回归被锁屏保护拒绝。PR #145 暂为草稿，待解锁后补完最终实测，再评论和 squash 合并。
