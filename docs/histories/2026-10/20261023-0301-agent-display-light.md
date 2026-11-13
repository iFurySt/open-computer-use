## [2026-10-23 03:01] | Task: 实测并降低 agent display 的性能开销

### Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS 27 arm64`

### User Query
> 用户觉得 virtual display “对性能很糟糕”。先量（WindowServer CPU / 内存、GPU、能耗、被停靠 app 的 CPU 与帧率、创建销毁的全局开销），逐个试刷新率、hiDPI、尺寸、空闲销毁和 CGVirtualDisplay 的其他私有属性，确认 agent 的截图、AX、点击、输入在每个设置下仍可用，再把胜出的设置做进去。

### Changes Overview
**Scope:** `packages/OpenComputerUseVirtualDisplayShim`、`packages/OpenComputerUseKit`、`docs/references`

**Key Actions:**
- **[刷新率 60 → 24 Hz]**: 停靠窗口按显示器刷新率绘制（Chrome rAF：60 Hz 下 60 fps，24 Hz 下 24 fps），没人看。24 Hz 是 `CGVirtualDisplay` 接受的下限（SkyLight `minimumRefreshRate = 24`，23.9 / 20 / 10 / 5 / 1 Hz 的 `applySettings:` 返回 NO）。`AgentDisplay.refreshRate` 默认 24，`OPEN_COMPUTER_USE_AGENT_DISPLAY_REFRESH_HZ` 可调，低于 24 按 24。
- **[hiDPI 1 → 0]**: 两种设置下显示器都以 1x 1920x1080 启动、开销没有差别；hiDPI=1 只是多给 9 个 HiDPI 模式。改成 0 是为了让同一身份的显示器以后不会以 2x 模式出现（同样的点用四倍像素）。
- **[restore 后不再保持可见]**: `get_app_state` 会给可见窗口加 occlusion keep-alive，停靠窗口总是可见，于是 restore 回到被遮挡位置后仍被固定为 visible，app 继续按用户屏幕刷新率绘制（ProMotion 上 118.6 fps，Chrome 16.9% CPU），直到 turn 结束。现在 agent display 上的窗口不加 keep-alive，restore 后回到停靠前的 hidden 状态（0 fps）。
- **[开销检查]**: `AgentDisplayLiveTests/testParkedWindowCost`（opt-in）走生产 `park` / `restoreAll`，分覆盖、停靠、恢复三段输出 Chrome 帧率与 CPU、WindowServer CPU 和点击到截图延迟，并断言停靠帧率不超过刷新率、恢复后不再绘制。
- **[文档]**: 新增 `docs/references/agent-display-cost.md`（英文，全部数字、噪声说明与复现方式），更新参考目录与 RELIABILITY 命令。

### Design Intent (Why)
开销大头是被停靠的 app 本身：Chrome 停靠在 60 Hz 显示器上 CPU 7.6–8.3%（大动画 14.4%），24 Hz 下 4.6–4.8%（7.4%），四轮结果稳定。WindowServer 在本机被其他 agent 与用户操作占到 35–50%，只有 60 Hz 的差值在四轮里方向一致（空闲显示器 +2.3 到 +3.1 个点，停靠动画窗口 +4.0 到 +5.2），24 Hz 的差值落在噪声内。点击到截图延迟由 `sky_click` 自身约 90 ms 的间隔主导，60 Hz 与 24 Hz 下中位数都在 95–102 ms，点击返回后的第一次截图在两种刷新率下都已是新内容；自己变化的内容在 24 Hz 下最多旧 42 ms（60 Hz 为 17 ms）。

没有做的：尺寸保持 1920x1080，800x600 在 CPU 与 WindowServer 内存上都没有量出差别，反而会让比显示器大的窗口挂在外面或被 app 缩小，而 restore 只还原位置。空闲销毁保持原样：每次创建约唤醒 25 个 GUI 进程、0.9–1.1 CPU 秒，销毁 0.6–0.9 CPU 秒，约等于空闲 24 Hz 显示器 80–400 秒的开销，延迟销毁只在连续停靠时划算，且要改生命周期代码，与并行的排列修复分开。`refreshDeadline`、`isReference` 被接受但不改变帧率；没有能让菜单栏、Dock、壁纸不画到这块显示器上的属性。

代码改动只在 shim 的一行设置、`AgentDisplay` 的一个常量和创建调用、snapshot 的 keep-alive 条件，和并行修改 `AgentDisplay` 生命周期的分支不重叠。

### Validation
- 扫描用临时 harness（不入库）在 GUI 锁内跑：每个配置 4–5 轮交替顺序、每轮 10 s，WindowServer 用同轮配对差值的中位数；结果与噪声见参考文档。
- `testParkedWindowCost`：上游设置下恢复后 118.6 fps、Chrome 16.9%（断言失败，即修复前的问题）；本改动 60 Hz 下停靠 60.9 fps、恢复后 0 fps；默认 24 Hz 下停靠 23.8 fps、恢复后 0 fps、Chrome 0.5%；5/5 次点击都在截图里出现（105–140 ms）。
- `OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST=1 swift test --filter AgentDisplayLiveTests`：本改动下 5 次里 3 次通过，另外 2 次只因测试期间有人移动鼠标 / 切换前台 app 失败；上游设置对照 2 次里 1 次同样因鼠标移动失败。网页内容、截图、点击输入、恢复位置与显示器移除在每次里都通过。
- 结束后在线显示器只剩内建屏 `0,0 1512x982`，测试 Chrome 与 fixture 均已退出。
- `swift test`：383 项，8 项跳过（opt-in live 测试）；6 次运行里 5 次 0 失败，第 1 次有 1 项失败但输出未保留，之后 5 次未复现。

### Files Modified
- `packages/OpenComputerUseVirtualDisplayShim/OpenComputerUseVirtualDisplayShim.m`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AgentDisplay.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AgentDisplayLiveTests.swift`
- `docs/references/agent-display-cost.md`
- `docs/references/README.md`
- `docs/RELIABILITY.md`
