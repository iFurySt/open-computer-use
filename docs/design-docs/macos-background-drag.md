# macOS 后台拖拽修复：PR 说明草稿

状态：设计 / PR 草稿；尚未实现 OCU runtime 修复，不可据此标记 ready for review。

执行计划：[macOS 后台拖拽修复](../exec-plans/active/20261110-macos-sky-drag.md)。以下内容可用于后续 Draft PR；实现和测试完成后应据实际 diff 更新措辞与检查项。

## 建议 PR 标题

`fix(macos): deliver drag events correctly to background windows`

## 摘要

拟修复 macOS 原生 `drag` 在部分后台窗口中已完成事件投递、但目标控件没有产生实际拖拽效果的问题。

本次聚焦现有 `drag(app, from_x, from_y, to_x, to_y)` 的运行时实现，不新增工具，不增加曲线 / 贝塞尔 / points 参数，不预设 `drag_method` 或 `sky_drag` API。目标是调用方无需改变现有请求，即可在已验证的后台窗口场景中完成起点到终点的拖动。

当前仅有可行性原型和一次原生工具复现，以下修复与测试仍待完成。

## 问题与复现

实测环境：macOS 26.6.2，已安装 OCU 1.1.4，Preview 绘制工具。源码调研基线为 `fccf49a`；尚未从该 checkout 构建并重跑复现，不能将已安装版本的结果写成该提交的构建验证。

1. 在 Preview 打开一张测试自有的 800×650 白色 PNG，保持 Preview 为后台应用。
2. 调用 `get_app_state` 获取新快照，并使用 `click_method=accessibility` 选中“绘制”。
3. 保持全局指针选项未开启，按该次返回截图的像素坐标调用原生 `drag`。

实测请求（当时返回截图为 1280×1256；其他窗口尺寸应重新选取画布内坐标）：

```json
{
  "app": "com.apple.Preview",
  "from_x": 400,
  "from_y": 450,
  "to_x": 850,
  "to_y": 800
}
```

**实际结果**：工具返回 `Drag delivered via app_post`，绘制工具保持选中，但动作返回截图和再次观察均显示画布空白。操作前后读取的前台应用均不是 Preview。该次鼠标位置两次读数不同，不以此声称该次实测证明了指针不动。

**预期结果**：画布产生对应的拖动笔迹，同时不激活或抬升 Preview、不移动系统指针、不破坏真实前台窗口的 key / first responder 状态。

本复现仅说明 Preview 画笔场景失败，不宣称所有应用都无法接收现有 `app_post` 拖动。`Drag delivered` 描述投递路径，不应被解读为目标 UI 动作已成功。

## 调研结论与待确定项

目前调用链：

```text
ComputerUseToolDispatcher
  -> ComputerUseService.drag
  -> performDragEvent
  -> InputSimulation.dragTargeted(from:to:pid:)
  -> CGEvent.postToPid
```

默认实现生成 move / down / dragged / up，但 `dragTargeted` 只接收起终点与 PID，没有复用现有 SkyLight 输入代码的完整目标窗口 / 合成焦点处理。

独立原型在 Preview 中组合使用以下处理后完成了后台落笔：

- 目标应用 synthetic-active 与 make-key-window record；
- 目标 PID / window、window-local location 及其他事件字段；
- HID event source、事件间隔和公开 `CGEvent.postToPid` 投递；
- 结束后撤销目标合成激活状态。

原型未调用系统级 `.cghidEventTap`。各次原型绘制期间抽样未发现目标变为前台，绘制前后指针读数一致；这不是连续的完整焦点 / 窗口层级验证。

**这些是组合可行性证据，不是最小根因证明。** 原型还有画布特定的取消选中点击，留下了额外小点；不能将该脚本直接搬进生产代码。需对焦点、窗口字段、event source 和时序分别做对照，确认最小处理和兼容性。

## 拟修改范围

1. 用真实 AppKit 画布和正常输入事件建立回归，不通过 FixtureBridge command 直接伪造成功结果。
2. 根据对照测试，在现有后台拖动实现中补齐必要的窗口定向和输入状态处理；优先复用 `SkyLightSPI`，不复制私有符号桥。
3. 保留既有起终点 API、截图像素坐标语义、显式启用的 global 路径及其安全门，不增加调用方迁移步骤。
4. 在发送前验证目标窗口身份、几何、坐标及会话状态；动作中止后仍保证本次按下的按钮和合成状态得到清理。
5. 后台路径的动作回读不得通过 activate / raise 补救。私有能力不可用或目标失效时明确报错，不偷偷改成全局鼠标；默认后台路径是否采用该机制须经维护者确认并有兼容性证据。
6. 同步实现说明、使用文档、history 与面向用户的 release note。

拟重点影响：

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- 如有必要，新增独立拖动实现文件并复用 `SkyLightSPI.swift`。
- 真实输入测试 fixture、故障清理单测及 opt-in live tests。

不计划扩展 native schema、JS API 或修改 Windows / Linux 行为；既有跨平台 contract 仍须回归。若最终证明必须新增公开选项，应先更新设计并讨论，而不是在本 PR 中顺带扩大接口。

## 安全、风险与兼容性

- **私有 ABI 风险**：动态探测能力，缺失或失败时明确报告；不通过静默 global fallback 绕过非侵入边界。
- **重复事件风险**：不能照搬 `sky_click` 的 primer / 双通道投递；验证每次只产生一组预期手势，不增加目标坐标外的点击。
- **状态泄漏风险**：按下前准备 release；按下后所有异常路径尝试松开，清理不应因动作许可过期而被跳过；最后撤销合成焦点。
- **默认行为变化**：即使请求格式不变，后台事件语义仍可能影响原本可用的应用；必须验证既有 app_post 用例和全局路径，不能仅凭 Preview 原型直接替换。
- **能力范围**：首个目标是已验证画布上的后台拖动；未测试的 Chromium、其他 Space、标题栏移动、文本拖选、Finder 拖放不作兼容承诺。
- **权限与桌面**：不改权限、安装、Locked Use 或虚拟显示器配置；真实 UI 测试显式 opt-in，先约定无人输入时段。

## 验证与合并门槛

已完成：

- [x] 阅读贡献、协作、架构、安全与可靠性规范。
- [x] 使用已安装 OCU 原生 drag 复现 Preview 后台画笔无效果。
- [x] 独立脚本组合方案在同类画布后台落笔，记录验证局限。

待实现 / 验证：

- [ ] 对照测试确定必要的焦点、窗口字段、source 与时序处理。
- [ ] 真实 AppKit 输入 fixture 收到且仅收到预期 down / dragged / up，并验证实际笔迹。
- [ ] 目标窗口完全遮挡时验证拖拽效果。
- [ ] 观察真实前台 PID、active、key、first responder、resign 计数和窗口层级，排除瞬时抢焦点。
- [ ] 连续观察真实指针位置；完成后验证目标合成状态释放。
- [ ] 注入缺符号、窗口关闭、会话失效、按下前 / 后及中途失败，检查停止、release 与焦点清理。
- [ ] 验证截图坐标 / Retina / 窗口移动和窗口身份守卫。
- [ ] 保持现有输入及 global 授权边界，动作回读不激活目标。
- [ ] `swift test`。
- [ ] `node --test scripts/node-repl/*.test.mjs scripts/tests/*.test.mjs`。
- [ ] Windows / Linux runtime 的 `go test ./...`（按可用环境记录实际执行范围）。
- [ ] 新增后台拖动 opt-in 实机回归；命令以最终测试名为准。
- [ ] 最终 `make check-docs`、`make ci`，如有未执行项明确列出。
- [ ] 补齐 `docs/histories/` 与 `docs/releases/feature-release-notes.md`，将已确认能力及限制写进说明。

未执行的检查不得在最终 PR 中写成已通过。当前无 runtime 代码 diff，不能将本草稿作为已完成的修复提交。

## 非目标

- 不实现苹果形状、曲线生成、贝塞尔采样或路径规划；这些属于 Agent 的任务逻辑。
- 不新增 points / 持续手势协议，不将多次独立 drag 宣称为一条连续曲线。
- 不新增工具，不预设 sky_drag API，不复刻 Codex 的闭源实现。
- 不 bump 版本、不发布制品、不修改用户已安装的 OCU。
