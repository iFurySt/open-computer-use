# Locked Use

[English](locked-use.en.md)

Locked Use 可以让 Agent 在 Mac 锁屏时继续操作 GUI。期间所有屏幕都有遮罩，任务结束或你移动鼠标、按键时，会重新锁屏，再由你正常解锁。

## 如何开启

需要 macOS 14 或更新版本，以及包含 Locked Use 组件的签名 OCU App。签名的正式构建会默认包含这些组件；自行构建开发版时设置 `OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=1`。

先正常解锁 Mac，然后运行下面的命令，完成管理员授权：

```bash
ocu locked-use enable
```

这个命令会安装所需组件，先确认授权插件能被 macOS 加载，再请求主 App 和 Guardian 的权限。加载检查失败时，不会把插件接入系统锁屏认证。不需要手动修改配置。Locked Use 不会随 OCU 的普通权限引导自动开启。

```bash
# 查看安装和权限状态
ocu locked-use status

# 停用并卸载，恢复原来的系统锁屏认证规则
ocu locked-use disable
```

更新 OCU 不会自动替换 `enable` 安装的系统组件。如果 `status` 显示已安装和 App 内置的插件版本不同，先完成未结束的恢复，再执行 `ocu locked-use disable`、`ocu locked-use enable`，重新安装。

如果正常手动解锁时偶尔长时间转圈、连续重试却很快，可以用仓库里的 `python3 scripts/measure-locked-use-auth-latency.py` 在已解锁状态测量插件首次加载和重复调用的耗时。它不锁屏、不修改认证规则；需要已有 Locked Use 安装。复现证据、公证票据分发修正与仍待验证的边界见 [冷加载诊断](references/macos-locked-use-cold-auth-latency.md)。

## 需要什么权限

在「系统设置 → 隐私与安全性」中允许：

| 组件 | 权限 | 用途 |
| --- | --- | --- |
| Open Computer Use | 辅助功能、屏幕录制 | 读取和操作目标 App，获取截图 |
| OCU Guardian | 辅助功能、输入监控 | 操作锁屏 UI，检测本地键鼠接管 |

安装、卸载还需要管理员授权。Broker 和授权插件不需要单独申请上述权限。开发版的 App 名称会带 `(Dev)`。

`enable` 会发起权限申请。若需要再次申请 Guardian 权限，可以运行：

```bash
"/Library/Application Support/OpenComputerUse/LockedUse/OCU Guardian.app/Contents/MacOS/OCUGuardian" --request-permissions
```

## 会安装什么

下表中的 `ROOT` 指 `/Library/Application Support/OpenComputerUse/LockedUse`。主 App 沿用你已有的 OCU 安装，开启 Locked Use 时会新增：

| 组件 / 文件 | 安装位置 | 用途 |
| --- | --- | --- |
| OCU Guardian | `ROOT/OCU Guardian.app` | 显示遮罩，处理解锁、重锁和本地接管 |
| Broker 服务 | `ROOT/OCULockService` | 管理授权许可、任务租约和保护状态，以 root 身份运行 |
| 安装器 | `ROOT/OCULockInstaller` | 安装、卸载和恢复组件，按需以管理员权限运行 |
| 授权插件 | `/Library/Security/SecurityAgentPlugins/OCULockAuth.bundle` | 系统认证时向 Broker 查询是否允许解锁 |
| launchd 服务定义 | `/Library/LaunchDaemons/dev.opencomputeruse.locked-use.broker.plist` | 启动并维护 Broker 服务 |
| 状态文件 | `ROOT/` 下的 JSON 文件与 `run/` 目录 | 保存安装、批准、验证及恢复记录和本地通信 socket，由程序维护 |

安装还会登记自己的授权规则，并为 `system.login.screensaver` 加入 Locked Use 分支，保留系统原有的认证方式。正常卸载会恢复原规则并移除上面的组件。

## 这些服务怎么配合

OCU 负责实际操作目标 App。锁屏时，它先向 Broker 申请任务租约。Broker 决定是否允许任务继续；Guardian 负责遮住屏幕、操作锁屏 UI，并持续报告保护状态。系统发起认证后，授权插件向 Broker 查询许可，认证仍由系统完成。

Guardian 还有一个独立的 watchdog 进程，使用同一个 App，负责主保护进程异常时的备用遮罩和恢复。它不是另外一个需要安装的 App。

![Locked Use 架构](assets/locked-use-architecture.png)

图中的 OCU Locked Use Broker 对应 `OCULockService`，Authz Plugin 对应 `OCULockAuth.bundle`；`loginwindow` 和 `launchd` 都是 macOS 自带组件。图中的 `SecurityAgentHelper` 是旧路径标注；无 UI 授权机制现在使用系统的 `authorizationhosthelper`（privileged host）。图中未单独画出 watchdog。
