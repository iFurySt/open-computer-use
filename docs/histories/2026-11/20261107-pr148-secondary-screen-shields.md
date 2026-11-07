# PR #148：副屏遮罩初始坐标

## 用户诉求

处理 #148，并确认为什么此前双屏开发验证通过，本次仍报告副屏覆盖失败。

## 实现与判断

保留贡献者的屏幕局部坐标修复。旧代码传入全局矩形，造成初始位置重复叠加屏幕原点；修复仅调整初始化，后续全局定位、严格覆盖和认证边界不变。删去“任何副屏最终都会失败”的过强注释。

真实运行生产窗口创建和覆盖代码，对比初始化、setFrame 后和显示后的状态。本机双物理屏与三屏混合缩放场景下，旧版均能由 setFrame 修正初始偏移；修复版从初始化即正确。此前双屏验证有效；报告者环境的最终纠正失效尚未复现，未擅自归因于操作系统版本或虚拟屏。

## 验证

- 两版 × 物理双屏 / 增加左侧 1920×1080 虚拟屏，四组真实检查通过；测试后独立进程确认原显示器列表、位置和缩放恢复。
- `swift test`：444 项，9 跳过，0 失败。
- 没有修改安装组件、认证规则或请求锁屏 / 解锁。复现入口与限制见 [副屏遮罩坐标](../../locked-use-shield-placement.md)。

## 主要文件

- `experiments/LockedUse/Sources/Guardian/DisplayShieldSurface.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LockedUseShieldCoverage.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LockedUseShieldCoverageTests.swift`
- `scripts/tests/macos-shield-placement-smoke.py`
- `scripts/tests/fixtures/MacOSShieldPlacementFixture.swift`
