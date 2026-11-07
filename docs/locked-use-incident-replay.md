# Issue #157：Locked Use 收尾复现

#158 修复正常连接下的清理报告被拒绝，并补齐 Guardian 重连时丢失释放指令的问题。真实签名组件的锁屏验证按维护者决定，留到后续小版本。

## 怎么复现

```sh
swift test -j 4 --filter LockedUseIncidentReplayTests
swift test -j 4 --filter LockedUse
```

用生产 `LockedUseBrokerCoordinator`、`LockedUseStateMachine` 和 `LockedUseGuardianPolicy` 组合回放，并经过生产 IPC 消息的 JSON 编解码。系统 session、窗口遮罩就绪状态、认证后的 peer context 和时钟由测试提供。测试不会锁电脑、安装服务或读取密码。

`testIdleTimeoutReleasesBothGuardsAndDoesNotRelockUser` 检查正常收尾；`testReconnectConsumesReleaseBeforeNextReport` 通过生产 `LockedUseGuardianBrokerExchange` 处理恢复握手，再发送普通报告，确认释放不丢失。`DisplayGuardian` 使用同一编排函数和统一的 `applyBrokerReply` 执行两种回复。额外测试覆盖拒绝回复、传输失败、完成后晚到回复以及握手处理完成后不再报告。

## 回放顺序

1. 注册主 Guardian 和 watchdog，领取并消费许可，观察到已解锁，进入 active。
2. 连续发送两端健康报告，虚拟时钟推进 30 秒，生产状态机实际触发 idleTimeout。没有直接调用 end 来代替超时。
3. 主 Guardian 报告已锁屏并停止，agent 确认 quiesced；Broker 进入 idle，等待释放确认。
4. 正常连接：主 Guardian 继续报告，收到 releaseGuards。Guardian 策略确认排空和锁屏展示就绪后输出 releaseShield；后续解锁不再输出 requestRelock。
5. 验证两种释放确认顺序：主 Guardian 先 / watchdog 先。只有两者都确认才能开始下一租约。错误 Guardian、旧/错误 lease ID 和提前 begin 均被拒绝。
6. 重连故障：在第 4 步之前发送 guardianRecoveryHello。Broker 将 releaseGuards 放进握手回复并清空待发队列；原 AppKit adapter 只检查回复是否 denied，丢弃 effects。后续正常 report 已拿不到 releaseGuards。补充修复现在先消费握手 effects，再发送 report。
7. 修复后主 Guardian 确认排空，在观察到锁屏展示就绪后退出；用户后续解锁不再产生 requestRelock。两端 ACK 到齐后可以开始新任务。

## 修复前后对照

2026-11-07，以 #158 的 6895880 为基础，在独立临时源码副本执行：

| 版本 / 场景 | 结果 |
| --- | --- |
| #158，正常连接 | 两端释放、再次解锁不重锁、下一次租约通过；两种 ACK 顺序均覆盖 |
| 仅还原 `let owner = machine.owner` 为原来的 `let owner` | 正向回放在 idle 后的 report 抛出 clientUnauthorized；2 项回放均在该处失败 |
| 原 #158，释放前重连 | report 不再抛异常，但释放指令仍丢失；可复现主 Guardian 重锁、watchdog 已释放、新租约被拒绝 |
| 补充重连修复后 | 握手释放指令被消费，主 Guardian 退出、后续解锁不再请求重锁、下一租约通过 |
| 仅撤回握手回复消费 | 新增正向回归出现 3 个失败：没有 releaseShield、再次 requestRelock、阶段仍为 relocking |

两次负对照分别撤回 Broker owner 修复、重连回复消费，测试文件不变。执行后均恢复修复。

## 证据边界和验收

该回放证实 issue 日志所述的因果机制，并证明一行修复能消除其中的报告拒绝；它不能证明报告者现场一定只有这一处原因，也不证明实际系统锁屏、签名身份或 IPC 断线恢复已通过。

后续小版本用签名组件验证连续两轮真实空闲超时、两端退出、手动解锁后不再重锁，并检查释放窗口发生断线的情况。本次测试覆盖真实的回复编排和策略，未运行系统 IPC 断线或 AppKit 遮罩。日志应包含租约阶段、停止原因、消息类型和效果名称，避免记录密码、许可 nonce 或完整 audit token。
