# macOS 原生后台拖拽

`drag` 的 MCP / JS 起终点接口不变。修复位于 macOS 默认后台投递实现，不增加 `drag_method`、曲线、贝塞尔或 points 参数。

## 问题与对照

旧实现只向 PID 发送 mouse move / down / dragged / up。在 Preview 画笔和真实 AppKit 画布中，`Drag delivered via app_post` 可以返回，但目标没有收到画布事件或留下笔迹。

在 macOS 26.6.2，使用同一个真实 AppKit 画布、相同直线 / 10 步 / 30 ms 间隔与公开 PID 投递做了以下对照：

| 输入上下文 | 画布收到完整手势 |
| --- | --- |
| 普通 PID 事件 | 否 |
| 仅 synthetic-active / key window | 否 |
| 仅窗口 ID 和 window-local location | 否 |
| 窗口信息 + synthetic-active，不设 key window | 否 |
| key window + 仅窗口 ID | 否 |
| key window + 仅 window-local location | 否 |
| synthetic-active + key window + 窗口 ID + window-local location | 是，1 down + 10 dragged + 1 up |

完整额外字段及 HID event source 的组合也能工作，但该画布不需要它们。生产实现保留既有 combined-session source、直线步数及节奏，只加入必要的窗口 / 焦点处理；不照搬 click 的 primer 或私有 / 公共双投递。这是该环境和画布的实测结论，不是对全部 toolkit 的断言。

## 实现与边界

- `BackgroundDragDispatcher` 验证当前 snapshot 的窗口 ID、PID、几何和窗口内端点；不按名称寻找替代窗口。负的屏幕坐标允许用于副屏，但局部端点不得越界。
- 事件增加 window-number 字段 51，以及 `CGEventSetWindowLocation` 的窗口内坐标。每个事件只公开 `CGEvent.postToPid` 一次，无额外点击、不改变真实鼠标。
- 仅后台目标通过已有 `SkyLightSPI` 获得 target-only synthetic-active 与 make-key-window record；通过系统级 AX focused application 实时判断真实前台，不依赖长驻 CLI 中可能过期的 NSWorkspace 缓存。目标已在前台时不添加合成状态，若手势期间目标成为真实前台，收尾也不撤销它的真实状态。
- 所有鼠标事件、每个可能停止位置的 release 在按下前分配并写入窗口位置。每次普通发送都检查会话和窗口；检查失败时停止新输入，但仍对仍属于原 PID 的原窗口尝试 release，最后撤销合成状态。cleanup 不被失效动作许可拒绝，cleanup 自身失败会报告。
- 私有能力缺失、目标隐藏 / 关闭 / 改变归属 / 移动时 fail closed。默认初始采集及动作回读使用 read-only recovery，不通过 activate / raise 修复快照，也不自动回退 global。
- 全局路径和已有 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 授权门不变；它可能移动真实鼠标或改变前台。
- 默认 `app_post` 的结果说明投递路径，不保证 UI 达到期望状态。WindowServer 管理的窗口移动、Finder 拖放、其他 Space 和其他 toolkit 尚无本修复的兼容承诺。

## 验证

### 单元测试

```sh
swift test --filter BackgroundDragTests
```

覆盖单次事件序列、窗口字段 / 局部坐标、前台目标及中途成为前台时不撤销真实焦点、缺符号 / 事件准备失败、每个发送边界窗口失效、会话初始拒绝 / 激活后及按下后许可撤销、release 最后位置、焦点清理失败、非有限参数与 read-only 回读策略。不需要真实输入权限。

### 真实 native MCP 测试

```sh
swift build --product OpenComputerUse
node scripts/tests/macos-background-drag-smoke.mjs .build/debug/OpenComputerUse
```

被测 OCU 需要正常 AX / Screen Recording 权限。测试编译独立 AppKit fixture，以两个测试自有应用构造真实后台画布和完全覆盖它的前台窗口，经 native MCP 获取快照并调用 `drag`。fixture 的控制文件仅允许清空观测、移动、关闭和显式激活测试窗口（最后一项只用于前台兼容性场景），不能制造鼠标事件或笔迹。

测试会短暂激活自有前台窗口，请在无人输入时运行；真实用户的键鼠操作会导致指针 / 焦点断言失败，不能把这种失败删掉或当成通过。测试不锁屏、不改变显示器、不启用 global、不操作用户文档。

断言实际 down / dragged / up、绘制回调、目标窗口号 / 坐标、合成状态释放、前台 active / key / first responder / 失焦计数、前台 PID 采样、真实指针采样与 z-order。另验证端点越界、窗口移动、窗口关闭后拒绝且不多发输入；关闭动画期间 WindowServer 可能仍保留缩小中的窗口，此时几何失效拒绝同样正确。最后显式激活自有目标，验证目标本就在前台时仍能拖动，且收尾不撤销它的真实前台状态。

要在未修复的授权 executable 上复现旧行为：

```sh
node scripts/tests/macos-background-drag-smoke.mjs <baseline-executable> --expect-baseline
```

此模式要求实际无笔迹，并不是修复的通过模式。观察初始化可能异步就绪，因此仅初始截图允许有界重读；状态改变动作绝不自动重发。

## 本轮验证记录

- 本 checkout 在修复前构建：真实 MCP baseline 无笔迹、画布事件数 0，前台与指针断言通过。
- 修复后 native MCP 主场景连续三轮通过：每轮 12 个画布事件，实际笔迹存在，前台状态 / 指针 / z-order 保持，目标结束后 inactive / 非 key。
- 扩展实机回归已完整通过：绘制回调、越界、移动 / 关闭守卫，以及同一长驻 MCP 进程内将目标切为真实前台后的兼容性。早期一轮被真实桌面操作打断，未计为通过；关闭动画的几何拒绝曾触发过窄的测试文案断言，修正了预期；前台兼容测试曾暴露长驻进程的前台识别问题，改为实时 AX 查询后通过。
- CLT Swift 6.3.3 可以构建运行时，但默认测试搜索路径缺 XCTest；本机完整 Xcode 的 Swift 6.4.2 在未修改的 `LockedUseIncidentReplayTests.swift` 出现编译错误。因此使用 CLT 编译、显式补充完整 Xcode 的 XCTest frameworks / usr/lib 路径，再使用其 `xctest` runner 执行。最终实跑结果：14 个新增单测通过；完整 XCTest 包 476 个测试，8 个 opt-in 等跳过，0 失败。单纯 `swift test` 返回“no matching test cases”不能算测试通过。
- `make ci` 通过，包含 JS、Python 和可用的 Go 回归；不替代实机输入验证。

本机工具链的备用命令如下，`XCODE_DEVELOPER_DIR` 由开发者指向完整 Xcode 的 Developer 目录；正常工具链无需这些额外参数：

```sh
F="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
L="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
swift test --build-system native \
  -Xswiftc -F -Xswiftc "$F" -Xswiftc -I -Xswiftc "$L" \
  -Xlinker -F -Xlinker "$F" -Xlinker -L -Xlinker "$L" \
  -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L"
"$XCODE_DEVELOPER_DIR/usr/bin/xctest" \
  "$(swift build --show-bin-path)/OpenComputerUsePackageTests.xctest"
```
