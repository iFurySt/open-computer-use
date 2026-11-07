# Locked Use 输入监控与独占设备

PR #143 / issue #142 报告：Karabiner 独占键盘后，原来的 IOHIDManager 整体打开失败，Locked Use 在准备阶段中止。贡献者通过逐设备打开恢复了输入回调，但“至少打开一个设备”无法证明键盘、指针等类别都还能观察。

## 当前实现

- 使用 IOKit 的 `independentDevices` manager 枚举设备，逐设备打开、注册回调和关闭。manager 不再同时管理这些设备的输入回调与生命周期。
- 只跳过 `kIOReturnExclusiveAccess`。权限、设备消失和其他错误仍使启动失败，已打开的资源会清理。
- 键盘、指针、消费控制按键中，所有已枚举类别都必须有可观察来源；只剩消费控制按键设备不算健康。支持组合接口，不能用一个鼠标代替被独占的全部键盘。
- 新增设备、移除设备或输入错误使当前监控失效，并通知 Guardian / watchdog 停止当前会话；不会在运行中的租约里自动换用未验证的输入来源。
- 停止先关闭状态与回调，再解除调度、关闭设备和 manager。重复停止无副作用，旧监听代次的回调不能影响重启后的监控。

主 Guardian 与 watchdog 仍分别运行监控；CG event tap、接管、认证、遮罩和释放条件不变。不记录 HID 值、按键内容、设备名称或序列号。

## 验证结果与未覆盖部分

2026-11-07，本机未安装 Karabiner：

| 检查 | 结果 |
| --- | --- |
| 真实 monitor + 可替换后端 | 9 项回归通过：正常输入、独占设备与类别缺失、空列表、权限 / 非独占错误、热插拔 / 输入错误、启动途中变化、停止与旧回调 |
| 完整 Swift 测试 | 453 项，9 项跳过，0 失败 |
| 签名 fixture + 本机真实 IOKit | 启动、健康维持、停止和重新打开通过 |
| 用户配合的 Shift 测试 | 收到 48 次 HID 活动回调，失败次数为 0 |
| 用户配合的鼠标 / 触控板测试 | 完善 AppKit 事件循环并增加可见 60 秒倒计时后，两版均收到 3680 次 CG 指针事件，HID 回调均为 0；系统活动时间确认实际操作，Secure Input 为 false |
| Karabiner 转发及 Secure Input | 本机尚未验证 |
| 完整受保护锁屏会话 | 本轮未运行 |

本机鼠标活动由 CG 事件路径观测到，原始 HID 路径两版均未收到；这不是本 PR 新引入的差异，也不能写成原始 HID 鼠标监控已验证。此前无可见倒计时的短时测试连 CG 事件也为 0，不作为判断用户是否操作的证据。

输入类别检查是必要条件，**不是所有被独占设备都被正确转发的证明**。Karabiner 会通过虚拟 HID 设备重发事件，但配置可能吞掉或改写输入；普通用户进程在 Secure Input 期间也可能收不到键盘事件。不能只凭 `open` 成功或其他设备产生了回调就宣布接管保护正常。参考 [Karabiner 架构](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md)与[隐私说明](https://karabiner-elements.pqrs.org/docs/privacy/)。

2026-11-07，维护者决定基于代码审查、现有回归与贡献者原始证据先合并修复，把 Karabiner 实机验证留到包含该修复的版本发布后。保持 #142 开放，届时请贡献者分别确认键盘 / 指针接管、Secure Input 和设备断开后的行为；现有模拟回归不替代这些测试。后续跟进见 [发布后待验证](releases/pending-validation.md)。

## 复现

```sh
swift test --filter PhysicalInputMonitorTests

# 使用已有 Guardian 签名身份，复用正常 Input Monitoring 授权。
# 只在 .build 中生成独立 fixture，不替换 /Library 中的安装组件。
python3 scripts/tests/macos-input-monitor-smoke.py \
  --signing-identity '<Developer ID Application identity>' --seconds 60 --panel
```

看到倒计时窗口或 `started` 后，在测试时段移动鼠标或按 Shift；分开测试两种输入。`completed` 输出 HID 活动次数、只读 CG event tap 的键盘 / 指针事件次数、失败次数、停止和重启结果。CG 对照只统计事件类别，不读按键内容或坐标；另外检查系统指针空闲时间，辅助判断操作是否发生在测试时段。活动计数为零仅证明启动与清理，不证明接管有效。诊断不锁屏、不解锁、不生成输入，也不读取输入值。`--baseline-ref ae8caf6` 可编译合并前的 monitor 作对照。可先用 `--build-only` 构建，再直接运行输出的可执行文件并传入 1–60 秒时长。

在 Karabiner 机器上应分别观察键盘和指针，不能用一次混合操作的总计数推断两个都正常。需记录具体场景及结果；只保留计数和状态，不记录输入内容。正常监听通过后，再按现有受保护会话流程验证主 Guardian 与 watchdog。
