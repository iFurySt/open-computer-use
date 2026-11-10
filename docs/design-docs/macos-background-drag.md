# macOS 原生后台拖拽修复

状态：已实现，PR 保持 Draft；验收范围和实际测试结果见下方记录，不代表全部 macOS toolkit 已支持。

- [执行计划](../exec-plans/completed/20261110-macos-sky-drag.md)
- [实现、对照实验与回归说明](../macos-background-drag.md)

## PR 标题

`fix(macos): improve background drag delivery`

## 问题

已安装 OCU 1.1.4 和本 checkout 修复前构建的默认 `drag` 在真实后台画布中返回 app_post 已投递，但没有画布事件或笔迹。Preview 也复现过相同现象。普通 PID 投递缺少可路由的窗口上下文；在本次 AppKit 实测中还需要目标的合成 key 状态。

## 代码范围

- 保留原有 MCP / JS 起终点接口和全局输入安全门，不增加工具或方法参数。
- `BackgroundDragDispatcher` 将窗口号和 window-local location 写入事件，后台目标复用已有 synthetic-active / make-key-window SPI，然后通过公开 `postToPid` 单次投递。
- 保留原有 event source、10 步直线和 30 ms 事件间隔；不加入 primer、双投递、曲线或画布取消选中的额外点击。
- 端点、窗口身份和几何检查；每次发送前校验会话；预先准备 release，取消后仍清理按钮和目标合成状态。实时读取系统 AX 前台应用，避免长驻 CLI 的 NSWorkspace 缓存误判；目标成为真实前台时不撤销它的真实状态。
- 默认后台路径的初始观察和动作回读禁止激活 / raise 恢复。私有能力缺失或目标失效时明确失败，不自动改走 global。
- 新增无真实输入副作用的单测、真实 AppKit/native MCP smoke，同步安全 / 架构 / skill / 用户说明 / history / release note。

## 实测与限制

- 对照实验确定在本画布上需要 synthetic-active + key window + window ID + window-local location 组合；单独提供任意部分不足。未把这些观察推广为所有应用的内部机制。
- 修复前本 checkout native MCP baseline：0 画布事件，无笔迹。
- 修复后主场景三轮连续通过：每轮恰好 1 down / 10 dragged / 1 up，真实画布有路径，目标状态释放；覆盖窗口的 active/key/first responder/失焦计数、前台 PID、指针及 z-order 断言通过。
- 扩展实机测试已完整通过：绘制回调、越界 / 移动 / 关闭守卫、同一长驻 MCP 进程内目标已在前台的兼容性。早期被桌面输入打断的轮次未计为通过；关闭动画文案预期与真实前台识别问题均已修正并复测。
- 非 GUI 单测与 CI 结果、工具链 workaround 见实现说明。普通 `swift test` 在本机不直接可用，不能声称该命令原样通过。
- WindowServer 管理的标题栏移动、Finder 拖放、其他 Space、其他 toolkit 仍未作为本次已验证能力。

## 风险与迁移

调用参数不变，但默认后台事件语义发生改善并增加私有 SPI 依赖。默认端点必须位于观察窗口内；窗口移动后需要显式重新观察。跨窗口 WindowServer 手势不作保证。缺私有符号时拒绝，不保留静默不生效的成功结果或全局 fallback。

对照和回归只使用测试自有窗口，不操作用户文档或修改已安装 OCU。真实桌面测试会短暂激活自有覆盖窗口，必须无人输入时进行。一般用户输入可能打断测试，其失败不能被忽略。

## 合并前检查

- [x] Runtime 修复和无 GUI 单测。
- [x] 修复前 native MCP baseline、修复后主场景三轮实测。
- [x] 本轮完整 XCTest 包 476 个测试（8 个跳过，0 失败），含 14 个新增单测；基础 CI 回归通过（工具链处理详情见验证说明）。
- [x] 扩展实机 smoke 在无人操作桌面时完整跑通，包含目标已在前台的兼容性。
- [ ] 维护者评审默认行为变化、私有能力失败语义和版本兼容范围。

PR 保持 Draft，不自动标记 ready，不发布制品或 bump 版本。
