# Locked Use 副屏遮罩坐标

#148 修正遮罩窗口的初始位置。`NSWindow(..., screen:)` 接受相对指定屏幕原点的坐标；`setFrame` 接受 Cocoa 全局坐标。旧代码把全局矩形直接交给前者，导致副屏初始位置多偏移一次屏幕原点。见 [Apple 初始化说明](https://developer.apple.com/documentation/appkit/nswindow/init(contentrect:stylemask:backing:defer:screen:))。

修复只在初始化时减去屏幕原点，保留后续全局 `setFrame` 和原来的 WindowServer 严格覆盖检查，不改变遮罩大小、透明度、层级、认证或释放条件。

## 为什么以前双屏能通过

旧代码紧接着调用 `setFrame`，在本机可以纠正初始偏移。因此此前两块物理屏幕的覆盖测试通过，与初始坐标用错并不矛盾，也不能说旧代码在所有副屏上都会失败。

2026-11-07 在 macOS 26.5.1 的实测：

| 屏幕 | Cocoa 原点 / 缩放 | 旧版初始化 | 修复版初始化 | 显示后的 WindowServer 覆盖 |
| --- | --- | --- | --- | --- |
| 物理主屏，2560×1440 点 | (0, 0)，2× | 正确 | 正确 | 两版都通过 |
| 物理副屏，1512×982 点 | (500, -982)，2× | 多偏移约 (500, -982) | 正确，仅有 AppKit 亚点取整 | 两版都通过 |
| 临时虚拟屏，1920×1080 点 | (-1920, 360)，1× | 多偏移 (-1920, 360) | 正确 | 两版都通过 |

虚拟屏位于 Quartz (-1920, 0)，与报告者同方向，和物理屏构成三屏、混合缩放环境。测试结束后，独立进程确认显示器列表、排列和缩放恢复原状。

报告者的 macOS 26.4.1 上出现了最终 `shieldBoundsMismatch`；本机复现了错误的初始位置，但没有复现后续纠正失效。不能据此断定系统版本、虚拟屏或时序中的哪一个是最终触发条件。这次修复消除了错误初始化，尚不能宣称完成了报告者环境的锁屏认证闭环验证。

## 复现命令

需要已解锁的 Mac 和至少两块屏幕。脚本会短暂显示真实遮罩，不安装组件、不拦截键盘、不锁屏或解锁。

```sh
# 当前代码：初始位置与最终覆盖都必须正确。
python3 scripts/tests/macos-shield-placement-smoke.py
python3 scripts/tests/macos-shield-placement-smoke.py --virtual-display

# PR 合并前的 main：必须观察到副屏初始化偏移，随后覆盖通过。
python3 scripts/tests/macos-shield-placement-smoke.py --baseline-ref 7c40742
python3 scripts/tests/macos-shield-placement-smoke.py --baseline-ref 7c40742 --virtual-display

swift test
```

脚本编译所选版本的生产 `DisplayShieldSurface`、`ShieldAppearance` 和几何代码，只去除包导入并插入只读采样；不会替换定位或覆盖算法。分别记录初始化、`setFrame` 后和显示后位置，再连续运行生产覆盖检查。虚拟屏使用仓库现有 shim，仅移动测试自有显示器，不保存永久排列；退出后复核清理。

四组真实测试通过。Swift 全量 444 项、9 项跳过、0 失败。这里验证窗口几何和覆盖，不覆盖系统认证、锁屏动画、显示器热插拔或后台 Guardian 重连。采样也会改变微小时序，不能用本机未出现最终失败来否定报告者的问题。
