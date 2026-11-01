# 控件树预算

`get_app_state` / CLI snapshot / JS `app.getAXState()` 共用各平台的快照遍历。默认仍是 1200 个节点、64 层，不需要新配置。

大列表不应让“取消”“打开”等窗口操作消失。现在先在有限候选里选择控件，再按原树顺序输出：可见操作控件和普通界面区域优先于列表内容，明确离屏的内容最后处理。祖先路径、元素绑定和连续编号都会保留；刷新后应使用新快照的编号。

| 平台 | 可见性来源 |
| --- | --- |
| macOS | 集合的 AXVisibleChildren，以及窗口/滚动区域内的元素几何 |
| Windows | UIA IsOffscreen；列表、树和表格分支延后 |
| Linux | AT-SPI SHOWING 和滚动区域几何；GTK 表格离屏坐标可以纠正不准确的 SHOWING |

Windows 在单次快照内批量缓存 UIA 属性，下一次观察重新获取；动作仍重新定位真实元素。实现使用 [UIA CacheRequest](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/caching-in-ui-automation-clients)。

未知或失败的可见性信息不会直接删除控件；也不按其他应用是否遮挡目标窗口判定隐藏。

输出节点仍受 `max_tree_nodes` 限制。为了优先级排序，候选发现另有上限：`max(64, min(max_tree_nodes, 2500) × 4)`，默认 4800，最多 10000。范围不足时输出 `[Accessibility tree truncated: ...]`。重复和无效引用也计入候选预算。深度预算保持有效；极小预算和超大 provider 不保证包含所有控件。macOS 集合摘要显示实际纳入的项目数量，不再把截取的子集说成从第 0 行开始的连续区间。

候选上限约束本轮逐项检查，不等于系统无障碍 API 的硬超时：macOS / Windows 的子项数组仍由应用提供，单次调用的耗时取决于目标应用。

## 真实回归

- macOS：`node scripts/tests/macos-tree-budget-smoke.mjs <signed-ocu-executable>`，2000 文件的 NSOpenPanel，在 1200 / 40 节点预算下检查按钮并实际点击取消；使用当前正常授权。
- Linux：在私有 Xvfb / D-Bus 中运行 `python3 scripts/tests/linux-tree-budget-smoke.py --native <native-executable>`，检查真实 GTK 2000 行列表、底部按钮和滚动后的最后一行。依赖与环境见 [Linux 动作回读](linux-action-read-back.md)。
- Windows：`scripts/tests/windows-tree-budget-smoke.ps1 -NativePath <native-executable>`，真实 WPF/UIA 2000 行列表与按钮；已接入 Windows observation workflow。

这些测试使用自己的窗口/目录。GTK 验证覆盖 X11 / AT-SPI，不代表 Wayland 或所有 toolkit。
