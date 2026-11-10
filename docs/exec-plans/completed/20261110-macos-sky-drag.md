# macOS 原生 drag 后台投递修复

## 目标

查清原生 `drag` 在 Preview 后台画笔无效果的原因，在现有起终点拖动实现中修复必要的窗口定向 / 输入状态处理。维持现有 MCP / JS 调用格式，不预设新增 `sky_drag` 工具或 `drag_method` 参数。

状态：已完成实现与验证，归档 execution plan；PR 保持 Draft 等待维护者评审。文件名保留早期方案的 sky-drag 名称，不表示接口决策。

## 范围与分层

- 包含：macOS native drag 实现、生产会话与窗口边界、异常释放、真实输入回归、文档、history / release note。
- 不包含：曲线 / points API、形状 / 贝塞尔规划、新工具、虚拟显示器、安装或权限变更、Windows / Linux 行为变化。
- Agent 负责路径规划；OCU 负责对目标窗口正确执行 down / dragged / up。本次只验收现有起点到终点手势。
- 当前公开 drag 每次调用都会按下并松开。原型直接发送底层事件，并不能证明现有 MCP 已支持一条任意连续曲线；该表达能力不在本 PR 范围内。

## 背景与关联资料

- 源码调研基线：`fccf49a`。
- 原生工具复现环境：macOS 26.6.2，已安装 OCU 1.1.4；本 checkout 修复前构建也已通过真实 AppKit/native MCP baseline 复现。
- [问题复现与 PR 说明草稿](../../design-docs/macos-background-drag.md)。
- [协作约定](../../REPO_COLLAB_GUIDE.md)、[架构](../../ARCHITECTURE.md)、[安全](../../SECURITY.md)、[可靠性](../../RELIABILITY.md)、[history 规范](../../HISTORY_GUIDE.md)、[release note 规范](../../releases/README.md)。
- 主要实现：`ComputerUseService.drag` / `performDragEvent`、`InputSimulation.dragTargeted` / `withPressedMouseButton`，以及现有 `SkyLightSPI`、SkyClick / SkyKeyboard 实现。
- 默认 drag 走普通 app_post，global 由现有环境门控选择。在 Preview 原生 drag 返回已投递但画布未变。
- 组合原型通过合成激活 / key window、窗口字段、event source / 时序等调整完成后台落笔；尚未隔离必要因素。原型含额外空白点击，不能直接用于生产。

## 实现顺序

1. 在真实 AppKit 画布稳定复现，不通过 FixtureBridge command 代替真实输入结果。
2. 隔离焦点、窗口字段、event source 和时序，确定最小必要处理；检查事件恰好一次，不照搬 click 的 primer / 双投递。
3. 优先在已有 drag 路径中复用 SkyLight 窗口 / 焦点能力，不复制 SPI 桥；判断默认路径兼容性并向维护者说明行为变化。
4. 复用截图坐标换算、窗口身份与会话守卫。按下前准备 release；动作失效时停止新输入但仍清理按钮和合成状态。
5. 后台动作回读使用不激活目标的恢复策略。缺能力或失效时明确失败，不静默升级为全局输入。
6. 补单测、opt-in 真实输入测试、使用说明、history 与 release note；不 bump 版本，不修改已安装 OCU。

## 风险与缓解

- 私有 ABI / toolkit 差异：能力检测、受控测试，不从单个应用成功推导全局兼容。
- 默认输入语义变化：保持调用格式；测试既有 app_post 用例与 global 授权边界。若确需新公开选项，先更新设计并讨论，不顺带扩接口。
- 重复事件 / 额外点击：按实际接收事件数量、位置和笔迹断言；不发送取消选中的诊断点击。
- 焦点 / 按钮泄漏：逐阶段故障注入、预备 release、检查 cleanup 顺序和失败信息。
- 用户桌面干扰：实机测试显式 opt-in，仅操作测试自有窗口，约定无人输入时段；不自动改变显示器或锁屏状态。

## 验证方式

- `make check-docs`；`swift test`；`node --test scripts/node-repl/*.test.mjs scripts/tests/*.test.mjs`；可用环境中的两个 Go runtime 单测；最后 `make ci`。
- 新增真实 AppKit 画布 / 后台拖动 live test，不以合成 bridge smoke 当成有效输入证明。
- 检查完全遮挡时实际落笔、事件不重复、真实前台 active / key / first responder / resign 计数和 z-order 不变、连续指针位置与目标合成状态清理。
- 缺符号、失效窗口、会话变化、按下前 / 后 / 中途失败、Retina 与坐标边界、动作回读不激活。
- 未验证的其他 Space、Chromium、Finder 拖放、标题栏移动及文本拖选明确记录为未知，不作承诺。

## 进度记录

- [x] 阅读贡献与相关工程规范，定位 native 输入调用链。
- [x] 用已安装原生工具复现 Preview 后台画笔无效果。
- [x] 完成有局限的独立组合原型验证。
- [x] 明确只修现有 drag，撤销早期预设的 sky_drag 参数方案。
- [x] 起草 PR 说明，明确已验证与待完成项。
- [x] 完成真实画布对照：窗口号 + window-local location + synthetic-active/key 组合有效，保留原 source / 时序；去掉原型额外点击。
- [x] 实现生产修复与无 GUI 单测；默认路径初始观察 / 回读保持 read-only。
- [x] 主场景三轮真实遮挡画布 / native MCP 通过；最终 14 个新增单测、XCTest 完整包 476 个测试（8 个跳过，0 失败）和 make ci 回归通过；本机工具链限制已记录。
- [x] 扩展 opt-in 实机 smoke 在无人输入时完整通过：绘制回调、越界、移动 / 关闭，以及目标已在前台的兼容性。桌面输入打断的一轮未计为通过。
- [x] 同步 history / release note 及 PR 设计说明，记录实际验证局限。

## 决策记录

- 2026-11-10：早期曾提议显式 sky_drag；经需求澄清撤销预设，目标改为修复现有 drag 的后台执行。是否必须扩展公开接口需另行论证。
- 2026-11-10：曲线与形状规划不纳入本 PR；保留当前起终点协议。
- 2026-11-10：原型只证明组合可行，额外点击、焦点和时序因素均须拆开验证，不能直接把原型当成完成的修复。
- 2026-11-10：真实 AppKit 对照后，只保留窗口号 / window-local location / synthetic-active + key；不需要 click 的 primer、额外整数字段、HID source 或双通道。实现与验证细节见 [后台拖拽](../../macos-background-drag.md)。
- 2026-11-10：长驻 MCP 前台兼容性回归暴露前台识别问题，改用同步系统 AX focused application；不依赖 NSWorkspace 的前台缓存，收尾时不撤销已成为真实前台的目标状态。
