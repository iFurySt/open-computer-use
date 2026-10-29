# 权限浮窗贴合列表：调查与实现

## 目标与最终范围

浮窗优先贴到权限列表的 `+ / -` 容器下沿；录屏页面有两个列表时选上面一个。没有 AX 时退回原来的设置窗口底边，有 AX 后使用精确定位。

## 已确认的证据

- 原始控制器独立渲染能复现浮窗位于整个设置窗口底部，未使用列表几何。
- 独立 App 的 AX 与录屏 preflight 均为 false，AXWindows 返回 -25211；CGWindow 元数据仍提供窗口外框。新实现同一状态下的面板 frame 与原窗口定位完全一致。
- 本机 ChatGPT/Codex Computer Use helper 26.1015.1001540 的 `SlimCore.SystemSettingsApp.cachedAudioRecordingHeadingBounds` 路径调用 AccessibilitySupport 的 focusedWindow、sections、descendant 与 frame。该静态证据不证明未授权时能获取列表边缘，也未据此宣称所有方案不可行。
- [PermissionFlow](https://github.com/jaywcjlove/PermissionFlow/blob/65434c9ae04dba97cf52c1dffbe3e4e62b547c82/Sources/PermissionFlow/UI/FloatingDropPanel.swift) 与 [AskForPermission](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/Flow/PermissionRequestFlowController.swift) 的定位函数均以外框为基准。

## 实现

- 窗口元数据定位不依赖 AX。只有 AX 已授权时才启动后台读取；0.4 秒读取节流，单次发现预算 0.8 秒，最多 64 个容器、10 层，不遍历应用行。
- 按文档顺序选第一个同时包含列表和两个增删按钮的容器，校验按钮几何及可见区域。长列表允许使用固定在可见区底边的控件。
- 窗口移动使用相对几何立即跟随；窗口大小与标题变化重新发现。读不到或上方控件不可见时回退窗口底边，不选择下方音频列表。
- 面板位于列表下方 8pt，宽度不超过列表或原定 530pt；固定高度 109pt，保留此前动画中断后恢复完整尺寸的修复。

## 验证

```sh
OCU_TEST_LANGUAGE=zh-Hans OCU_TEST_LIVE_SETTINGS_ANCHOR=1 swift test --build-system native --filter PermissionOnboardingTests
OCU_TEST_LANGUAGE=en swift test --build-system native --filter 'Permission|TCC|PermissionGranted'
```

公版中文 UI 回归 15 项通过，包含真实双列表录屏页的 opt-in 检查；英文权限回归 25 项无失败，其中 1 项实机 opt-in 检查默认跳过。同一定位源码此前还在真实 23 行辅助功能列表验证了溢出/固定增删控件布局。文档检查与 `git diff --check` 通过。覆盖无几何回退、获得/失去列表几何、动画中移动与中断恢复、双列表文档顺序、遍历预算和多显示器坐标转换。

前后对照图使用真实设置页截图作为背景，原生控制器在渲染进程中读取真实 CGWindow/AX 几何，无注入列表 fixture。授权渲染进程的两项权限均为 true；独立 App 实测两项均为 false 并验证回退。它们是独立原生渲染，不是完整授权流程截图。

## 限制

未修改现有 TCC 权限，未在正式签名包完整走首次授权，也未在用户原多屏缩放环境实测。有 AX 时录屏双列表页的浮窗可能覆盖下方音频区域的部分内容，该页面的引导目标仍为上方录屏列表。
