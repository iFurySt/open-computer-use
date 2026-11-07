## [2026-11-07] | Task: 保留已结束租约的 Guardian 清理通道

### Execution Context

- Agent: Codex
- Model: GPT-6
- Runtime: OmO Native

### User Query

排查 Locked Use 不可用及密码解锁后立即重新锁屏的问题，并向上游提交修复。

### Changes Overview

- 处理带停止原因的 Guardian 报告时，仅结束状态机仍持有的活动租约。
- 扩展现有释放确认用例，覆盖租约先回到 idle、Guardian 后续报告停止状态的顺序。
- 保留新租约必须等待 Guardian 释放确认的断言，并补齐发布记录与执行计划。

### Design Intent

连接身份在清理期间仍需保留，但不能把它当作已经结束的活动租约所有者。
否则状态机会抛出 `clientUnauthorized`，阻断后续释放流程。

### Validation

独立程序通过真实库 API 在原版复现失败，应用修复后完成释放并接受下一租约。
本机仅安装 Command Line Tools，XCTest 因缺少模块未能运行；随后在
[macOS CI](https://github.com/joyleiyc/open-computer-use/actions/runs/42342567222)
使用 Xcode 26.6 / Swift 6.3.3 确认新增用例在原版因 `clientUnauthorized` 失败，
修复后的 126 个 Locked Use 测试全部通过。签名桌面闭环未实测。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/LockedUseBrokerCoordinator.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LockedUseBrokerCoordinatorTests.swift`
- `docs/releases/feature-release-notes.md`
- `docs/exec-plans/completed/20261107-guardian-cleanup-after-idle.md`

### Maintainer reproduction

用户要求在工程层面复现 issue 并确认修复有效。新增
`LockedUseIncidentReplayTests.swift`，将生产 Broker 与 Guardian 策略组合，
以真实 idleTimeout、双保护、两种 ACK 顺序和 IPC JSON 编解码回放。
正常连接修复后通过；只撤回生产一行修复则复现 clientUnauthorized。
额外注入释放前重连，证实忽略握手 effects 仍会造成主 Guardian 重锁、
watchdog 已释放和新租约被拒绝。该用例记录已知故障，不代表重连成功。
完整 Locked Use 128 项通过；边界和复现方式见
[事故回放](../../locked-use-incident-replay.md)。没有安装组件或操作真实锁屏。

### Reconnect fix

用户确认补齐重连后合并，真实验证留到后续小版本。新增生产
LockedUseGuardianBrokerExchange 编排：先消费恢复握手回复，再发送普通报告，
两种回复共用 DisplayGuardian.applyBrokerReply。拒绝回复和传输错误继续失败，
完成后的回复不再执行；恢复请求失败或恢复期间任务已完成时关闭新连接。
原诊断用例改为释放成功的正向回归，另外覆盖顺序、拒绝、完成和传输错误。
撤回握手回复消费时复现 3 个断言失败；恢复修复后通过。
最终全量 Swift 回归：435 项，9 项跳过，0 失败；真实 OCUGuardian target 编译通过。
文档检查及 diff 检查通过。测试未安装系统组件，真实锁屏验证留待发版后。
