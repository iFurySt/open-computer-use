# PR #187：Locked Use 暗屏唤醒与保活

## 用户诉求

基于最新 main 审查 #187，有问题补充修复，通过后合并；本地不便进行完整真实锁屏测试。

## 改动

保留贡献者的租约前唤醒、显示器保活和上一轮释放等待。补充保活先于唤醒、获取异常清理、预检后断开检查、唤醒断言 ID 复用与释放。Broker 终态后继续保活到双保护释放，独立后台清理有 60 秒轮询预算和 360 秒系统断言上限；Observer 复用连接并在故障后重建。

原因：`idle` 早于双保护 ACK，原 PR 在终态立即释放可能让清理再次遇到暗屏；连接或请求抛错时原保活也会遗留在长驻连接里。原 Broker 安全策略、手动解锁要求及用户系统配置保持不变。

主要文件：

- `apps/OpenComputerUse/Sources/OpenComputerUse/LockedUseDisplayPreflight.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/LockedUseConnection.swift`
- `apps/OpenComputerUse/Tests/PermissionOnboardingTests/LockedUseDisplayPreflightTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LockedUseIncidentReplayTests.swift`
- `docs/locked-use-display-readiness.md`、`docs/ARCHITECTURE.md`、`docs/RELIABILITY.md`

## 验证

18 项显示器回归通过，包含已解锁桌面的真实电源断言创建 / 释放。完整 Swift 测试 481 项，10 项条件跳过，0 失败；其中新增 opt-in 电源测试已单独执行。真实暗屏锁屏、签名组件自动解锁和重锁闭环未执行，需后续在报告者环境验证，不能以离线回放替代。

基础 CI 通过，含 Node、Linux Python、Windows / Linux Go 回归。两组负对照分别撤回获取错误清理与双保护等待，新增测试均在对应断言失败；恢复修复后全部通过。远端 CI 与合并状态以 PR #187 记录为准。
