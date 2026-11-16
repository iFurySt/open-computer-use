# Locked Use：暗屏唤醒与保活

Issue #186 报告：显示器休眠时，在线显示器仍存在，但 `CGGetActiveDisplayList` 返回 0。Guardian 无法确认遮罩覆盖，获取会话失败；重锁时若显示器再次休眠，也可能阻塞锁屏展示证据和双保护释放。报告者用 `caffeinate -d -u` 跑通了两轮；这不是本次补丁完整实测通过的证据。

## 处理方式

- app agent 在申请租约前创建 `PreventUserIdleDisplaySleep` 保活。暗屏时通过 `IOPMAssertionDeclareUserActivity` 唤醒，每 250 ms 检查一次，最多等待 4 秒。重试复用系统返回的断言 ID，结束时释放。
- 如果上一轮已进入 `idle`，但双保护尚未释放，再给清理过程 4 秒轮询预算。Observer 连接复用；单次在途 IPC 仍有自身超时，首次认证回复预算为 8 秒，因此这里不是整个预检严格 4 秒的墙钟上限。
- 获取连接报错、请求抛错、被拒绝或客户端已断开时，尚未移交给租约的保活立即释放。
- 租约进入 `idle` / `awaitingManualUnlock` 后，只有 `guardsReleased == true` 才立即结束保活。否则独立等待双保护确认，最多轮询 60 秒；Observer 暂时不可达会重试，不把失联当作释放。该等待不阻塞客户端，单次在途 IPC 同样可能超出轮询预算。
- 保活自创建起还有系统级 360 秒上限（最大租约 300 秒 + 60 秒），超时自动释放；进程退出也会释放。

预检失败仍由 Broker / Guardian 决定是否准入。没有跳过显示器覆盖、输入接管、重锁展示或人工解锁恢复条件，也不改变系统休眠设置。不会直接解除已经锁存的 `awaitingManualUnlock`。

## 验证

```sh
swift test -j 4 --filter LockedUseDisplayPreflightTests
swift test -j 4 --filter LockedUseIncidentReplayTests
swift test -j 4

# 可选：仅在已解锁桌面验证真实电源断言创建和释放，不熄屏、不锁屏、不唤醒
OPEN_COMPUTER_USE_TEST_POWER_ASSERTIONS=1 swift test -j 4 --filter LockedUseDisplayPreflightTests
```

2026-11-12：18 项显示器相关测试通过，含上述 opt-in 的真实电源断言检查；完整 Swift 测试 481 项，10 项按条件跳过，0 失败。默认跳过项包含本次 opt-in 测试，已单独执行通过。

获取阶段还用生产 `LockedUseConnection.acquire` 注入连接失败和预检期间断开，验证长驻客户端不遗留保活、断开后不再联系 Broker。两组负对照分别撤回获取错误清理和双保护等待，新增测试均按预期失败；恢复后通过。

注入时钟测试覆盖暗屏重试、醒不过来的超时、断言 ID 复用与释放、双保护延迟确认、Observer 失联及清理超时。事故回放使用生产 Broker 和 IPC 编解码，验证 `idle` 和第一个保护 ACK 之后 `guardsReleased` 仍为 false，两个 ACK 到齐才为 true。

本轮没有执行签名组件的真实暗屏获取、自动解锁、任务、重锁闭环。后续在报告者环境连续跑两轮，检查从暗屏唤醒、任务期间不再次休眠、两层保护都释放、下一轮可获取，以及失败后保活能够消失。已有 `awaitingManualUnlock` 必须先正常人工解锁。
