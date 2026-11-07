# Issue #157：Locked Use 收尾复现

#158 修复了正常连接下的清理报告被拒绝。释放指令恰好经过重连握手时，主 Guardian 仍可能无法退出；不能据此认定所有重复锁屏问题都已解决。

## 怎么复现

```sh
swift test -j 4 --filter LockedUseIncidentReplayTests
swift test -j 4 --filter LockedUse
```

用生产 `LockedUseBrokerCoordinator`、`LockedUseStateMachine` 和 `LockedUseGuardianPolicy` 组合回放，并经过生产 IPC 消息的 JSON 编解码。系统 session、窗口遮罩就绪状态、认证后的 peer context 和时钟由测试提供。测试不会锁电脑、安装服务或读取密码。

`testIdleTimeoutReleasesBothGuardsAndDoesNotRelockUser` 检查修复效果；`testReconnectStillLosesReleaseWhenHelloEffectsAreDiscarded` 则**断言仍存在的缺陷**，通过不代表重连正确。后者显式模拟 `DisplayGuardian.reportToBroker` 当前丢弃 hello.effects 的行为，没有运行 AppKit adapter 本身。修复重连时应将其改为完整释放的正向回归，并覆盖实际 adapter 的效果消费路径。

## 回放顺序

1. 注册主 Guardian 和 watchdog，领取并消费许可，观察到已解锁，进入 active。
2. 连续发送两端健康报告，虚拟时钟推进 30 秒，生产状态机实际触发 idleTimeout。没有直接调用 end 来代替超时。
3. 主 Guardian 报告已锁屏并停止，agent 确认 quiesced；Broker 进入 idle，等待释放确认。
4. 正常连接：主 Guardian 继续报告，收到 releaseGuards。Guardian 策略确认排空和锁屏展示就绪后输出 releaseShield；后续解锁不再输出 requestRelock。
5. 验证两种释放确认顺序：主 Guardian 先 / watchdog 先。只有两者都确认才能开始下一租约。错误 Guardian、旧/错误 lease ID 和提前 begin 均被拒绝。
6. 重连故障：在第 4 步之前发送 guardianRecoveryHello。Broker 将 releaseGuards 放进握手回复并清空待发队列；当前 AppKit adapter 只检查回复是否 denied，丢弃 effects。后续正常 report 已拿不到 releaseGuards。
7. 此时 watchdog 可以收到 releaseWatchdog 并确认退出；主 Guardian 策略仍为 relocking，用户解锁观察会再次产生 requestRelock，下一次 begin 仍被拒绝。

## 修复前后对照

2026-11-07，以 #158 的 6895880 为基础，在独立临时源码副本执行：

| 版本 / 场景 | 结果 |
| --- | --- |
| #158，正常连接 | 两端释放、再次解锁不重锁、下一次租约通过；两种 ACK 顺序均覆盖 |
| 仅还原 `let owner = machine.owner` 为原来的 `let owner` | 正向回放在 idle 后的 report 抛出 clientUnauthorized；2 项回放均在该处失败 |
| #158，释放前重连 | report 不再抛异常，但释放指令仍丢失；可复现主 Guardian 重锁、watchdog 已释放、新租约被拒绝 |

负对照只撤回一行生产修复，测试文件不变。执行后已恢复修复；完整 Locked Use 回归为 128 项、0 失败，其中包括明确记录剩余重连缺陷的诊断用例。

## 证据边界和验收

该回放证实 issue 日志所述的因果机制，并证明一行修复能消除其中的报告拒绝；它不能证明报告者现场一定只有这一处原因，也不证明实际系统锁屏、签名身份或 IPC 断线恢复已通过。

完整验收还需：让首次连接和恢复握手回复走同一个效果处理入口，增加实际 adapter 的断线回归；随后用签名组件验证连续两轮真实空闲超时、两端退出、手动解锁后不再重锁，并检查释放窗口发生断线的情况。日志应包含租约阶段、停止原因、消息类型和效果名称，避免记录密码、许可 nonce 或完整 audit token。
