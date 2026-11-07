## [2026-11-01 16:40] | Task: Keep Locked Use working when another tool seizes keyboards exclusively

### 🤖 Execution Context
* **Agent ID**: `hermes (default profile), user-supervised`
* **Base Model**: `claude-sonnet-5-5`
* **Runtime**: `Hermes desktop agent on macOS 26.4.1 arm64, OCU 1.1.2`

### 📥 User Query
> Locked Use fails whenever Karabiner-Elements is running. Fix it so both can coexist (see issue #142).

### 🛠 Changes Overview
**Scope:** `experiments/LockedUse` (Guardian)

**Key Actions:**
- **PhysicalInputMonitor fallback**: when the all-or-nothing `IOHIDManagerOpen` returns `kIOReturnExclusiveAccess`, open the matched devices one by one and continue if at least one input source is observable.
- **Cleanup**: devices opened individually are unscheduled and closed in `stop()`.

### 🧠 Design Intent (Why)
Karabiner-Elements seizes the built-in keyboard, Bluetooth keyboards and the TouchBar device and re-emits keys through its DriverKit virtual keyboard. The monitor only needs to know that *some* physical activity can be observed, so a seized device must not abort the whole Locked Use turn. Any other failure still aborts as before.

### 📁 Files Modified
- `experiments/LockedUse/Sources/Guardian/PhysicalInputMonitor.swift`


### 2026-11-07 维护者补充（待 Karabiner 实测）

- 同步最新 main，保留原贡献提交。
- 原“任意一个设备可打开即可继续”的条件改为类别覆盖校验；独立 manager 只枚举，逐设备管理生命周期，非独占错误仍停止。
- 新增 / 移除设备、回调错误和启动中变化均使监控失效；补停止、重启和旧代次回调保护。
- 新增 Guardian 测试目标与 9 项状态 / 异常 / 清理回归；完整 Swift 453 项，9 跳过，0 失败。
- 签名独立 fixture 的真实设备启动、停止、重启通过；本机无 Karabiner；用户配合的 Shift 测试收到 48 次活动回调。可见 60 秒鼠标对照中，旧版和新版均收到 3680 次 CG 指针事件，HID 均为 0；系统活动时间确认用户操作，不能将其写成原始 HID 鼠标或完整接管测试通过。没有改安装组件、认证规则或请求锁屏。
- 初次评审因缺少 Karabiner 实机验证暂缓合并。维护者随后明确决定先合并，在后续版本发布后请贡献者验证；#142 保持开放，未覆盖项仍如实保留。跟进见 [发布后待验证](../../releases/pending-validation.md)与 [输入监控说明](../../locked-use-input-monitor.md)。
