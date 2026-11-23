# macOS Locked Use

正常使用只需要三个命令：

```sh
ocu locked-use enable
ocu locked-use status
ocu locked-use disable
```

`enable` 安装签名组件、保留系统密码认证方式，并请求主 App 和 Guardian 的权限。正常启用不需要开发验证参数或历史验证报告。完整安装位置和权限说明见[中文使用指南](locked-use.zh-CN.md) / [English](locked-use.en.md)。

## 研发记录（历史行为）

以下保留研发过程与测试边界，包含旧版本的 profile、验证门槛及未完成的测试。这些记录不代表当前 enable 的开启要求；实际使用以上面的使用指南为准。


目标是在已登录用户的屏幕锁定后，允许已授权客户端临时解锁 GUI 会话，同时遮蔽所有物理显示器，继续通过 AX / ScreenCaptureKit / 输入执行任务，最后重锁。

**当前仍处于实机验证阶段，生产自动解锁默认关闭。** 已实现签名 root Broker、remote Authorization 机制、Guardian / 独立 watchdog、管理员安装 / 停用 / 恢复入口，以及 OCU GUI 请求的自动租约接入。真实 loginwindow 解锁、Secure Input 硬件交付与两类 Keychain 保持尚未通过实测；不能以离线测试通过或安装成功代替这些证据。

## 当前可用入口

```sh
ocu locked-use status
ocu locked-use status --json
ocu doctor
```

诊断分别报告 AX、Screen Recording 和 Input Monitoring 的当前进程 runtime preflight，以及会话状态、系统组件是否存在、其他 Authorization 插件名称和未完成的门槛。查询不请求权限，不安装、不解锁、不锁屏；安装文件存在也不表示签名、注册或运行已验证。`enabled` 来自 root 所有的安装配置；`available` 还要求 macOS build 和组件签名哈希与实测证据匹配。批准记录匹配当前 app agent 且安装认证规则完整也是 `available` 的必要条件。没有证据时生产自动解锁保持关闭。

原生诊断由 `.app` agent 执行，与真实控制进程保持相同权限身份。源码 CLI 的开发验证应绕过已经安装的旧版本 agent：

```sh
swift build
OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1 .build/debug/OpenComputerUse locked-use status --json
```

无完成登录的控制台 GUI session、切换用户或未知会话时，真实 app 控制明确拒绝。正常锁屏中的 GUI 请求由 app agent 尝试获取受保护租约；没有可用 Broker / 批准 / 验证 profile 时立即返回错误，动作自身的 session gate 仍拒绝无租约的锁定会话。缓存的真实 AX snapshot 每次复用前重新检查会话；输入事件投递和 AX 动作 / 属性变更路径补充检查。fixture 是测试数据，不代表真实桌面，仍可用于 headless smoke。会话检查不能提供与 WindowServer 事务原子性相同的保证。

## 保护状态机

`LockedUseStateMachine` 是由独立 Broker 串行驱动的纯状态 / effect reducer。真实解锁仍需管理员验证 profile 实测；执行 effect 不构成系统成功证据。

- `idle → preparing → authorizing → unlocking → active → relocking`
- 先收到全部显示器遮蔽、输入拦截和独立 watchdog 健康证据，才发一次性许可并请求解锁。
- 许可绑定 connection UUID、用户 UID 和 audit session；只允许认证后的插件回执消费一次，5 秒失效。
- 消费许可后还要确认相同会话已解锁，才能允许工具动作。
- 单调时间计时：3 秒 heartbeat 期限、10 秒启动期限、30 秒空闲期限、300 秒绝对租约上限。真实 guardian 需独立于 GUI action 维持 heartbeat。
- `turn-ended`、EOF、JS reset / timeout 或租约结束应撤销许可并重锁；app agent 已接入 turn-ended / EOF / 空闲期限；JS reset / timeout 结束原生连接，独立 EOF 监测可停止尚在执行的租约，动作完成后才确认排空。
- 本地输入、显示器 topology generation 改变、guardian 失效或会话异常立即停止并重锁；未知输入按接管处理。
- Broker 确认许可撤销已提交、解锁尝试取消 / 排空、动作投递停止后，还需确认原会话锁定，才能释放遮蔽。原锁屏仍可见不代表排队解锁已取消。未知 / 其他用户的锁定事件不算重锁成功；失败保留保护并重试。
- 接管和异常后进入 `awaitingManualUnlock`。正常人工解锁事件才清除抑制，排队请求不能重新解锁。

## Guardian 与锁屏实测

开发构建，不安装系统组件：

```sh
./scripts/build-locked-use-guardian.sh --identity 'Developer ID Application: <your identity>'
'.build/locked-use/OCU Guardian (Dev).app/Contents/MacOS/OCUGuardian' --diagnose
'.build/locked-use/OCU Guardian (Dev).app/Contents/MacOS/OCUGuardian' --peer-self-test
```

缺少权限时显式执行同一 binary 的 `--request-permissions`，由用户在系统设置授予 Accessibility 与 Input Monitoring。`--diagnose` 本身不请求权限、不锁屏。

先单独确认所有物理显示器遮蔽与倒计时，再验证遮罩期间的动作：

```sh
python3 scripts/run-locked-use-rehearsal.py --shield-preview
```

该独立 preview 复用 rehearsal 的显示器覆盖与 WindowServer 检查，覆盖确认后显示 15 秒倒计时。输入事件仅按类型 / source PID / source state 汇总，不保存按键或文本；鼠标移动不会提前结束，Esc 立即退出。它不创建 AX fixture、不截图、不执行应用动作、不启动重锁 watchdog、不请求锁定或解锁。结束或 controller 的开发应急超时只撤掉预览；不能复用该输入策略或超时退出作为生产保护。物理屏幕需人工观察，枚举的 NSScreen 数量也可能包含虚拟显示器。

**只有用户准备好锁屏、并有人观察物理屏幕时运行：**

```sh
python3 scripts/run-locked-use-rehearsal.py --confirm-lock-test
```

测试从已正常解锁的会话开始，创建专用蓝色窗口，再使用独立、覆盖所有 NSScreen 的黑色 window 遮蔽。它检查 WindowServer 中的窗口 PID、frame、alpha、layer 和物理显示器映射，不能把 `isVisible` 单独当成已覆盖。过滤型 session event tap 不读取或记录按键内容，对所有全局输入保守接管；定向 `postToPid` 不走这条全局 stream。Secure Event Input、tap disable、显示器 topology 改变、watchdog 失效均停止测试并请求锁屏。软件 overlay 无法提供原子热插拔、系统级 overlay 或进程死亡时零泄漏的证明，必须实际观察。

`shieldReady` 后，使用 AXPress 点击专用窗口按钮，并以 ScreenCaptureKit 的 desktop-independent window filter 验证遮挡后的蓝色内容和动作前后画面变化。AX / capture 未完成时不提前宣告 quiescence。输出只有结果与状态，截图不写磁盘。最长 15 秒租约到期或本地输入都会请求重锁；只有原 UID / audit session 观测到锁定、且动作已排空，才移除遮罩。

child watchdog 与 UI event loop 分离，监测 inherited pipe 心跳；1.5 秒超时、EOF 或非法输入会独立请求重锁。该测试 watchdog 从未接收解锁许可。测试完成后，Guardian 只读取 loginwindow 的 AX role / subrole / action names，最多 300 节点、12 层、3 秒；不读取值、用户名、输入框、选中文本或密码，也不执行 loginwindow 动作。单次 AX RPC 额外有 0.5 秒 timeout，因此整个 traversal 可能比预算略长。

独立 watchdog 的人工故障注入入口：

```sh
python3 scripts/run-locked-use-rehearsal.py --confirm-watchdog-test
```

受控 AX / SCK 闭环通过后，故意阻塞 Guardian 主线程 5 秒，停止该进程的 UI loop 和 heartbeat，已有遮罩窗口保留。watchdog 用 inherited pipe 的 `S` byte 回报实际重锁请求；Guardian 恢复时必须已经观测到锁定，之后策略再次确认原 session 锁定再释放窗口，才能报告测试通过。请求回报本身不算锁定证据。该实验只覆盖主线程卡死，不证明遮罩进程被杀死、热插拔或系统 overlay 时零泄漏；人工应保持输入静止并观察物理屏幕。

开发 controller 默认提前 5 秒提示用户放开输入。rehearsal 的非正常退出 / 35 秒超时会先保留 child watchdog，同时请求重锁并观察会话状态，再清理自身测试进程组；preview 的恢复不请求锁屏。这是只供人工实验的应急路径，**不能在生产 Locked Use 中用超时移除遮罩**。rehearsal 没有改变认证规则，也不自动解锁；用户随后按普通方式解锁。

事件输出包含单调时间与 capture 阶段 / stop reason，便于区分覆盖失败、输入接管、动作失败及租约到期。同进程受控 fixture 的 AXPress 在 MainActor 上执行；AppKit 会直接在调用线程派发按钮动作，不能从后台队列调用带 MainActor 隔离的 target。`--fixture-ax-self-test` 可独立验证此路径，不遮蔽、不锁屏。

### Broker 认证组件

- `LockedUseAuthorizationRules` 生成离线安装 / 恢复计划，只对现有 OR rule 添加本项目 branch，保留原 fallback 和其他语义字段。旧计划或原规则被更改、阈值不兼容、已有本项目引用时拒绝；规划本身不执行系统写入。Installer 已实现 root 存储、互斥和写入前后校验；验证 profile 的安装 / 卸载与原规则恢复已实测，生产和故障链仍待验证。认证事务的 opaque ID 不能当作 audit session，详见 [认证边界](references/macos-locked-use-authentication.md)。

- `LockedUseNative` 用 `LOCAL_PEERTOKEN` 获得 kernel audit token，包含 PID version；不把客户端自报 PID 转成身份。
- `LockedUsePeerIdentity` 用 token 查询动态 SecCode，并验证 administrator-approved requirement。
- `LockedUseClientApprovals` 固定从 `/Library/Application Support/OpenComputerUse/LockedUse/clients.json` 读取，逐层 `openat` / `O_NOFOLLOW`，检查 root ownership、group/other 不可写与无允许修改的 extended ACL，拒绝 symlink、非 regular file、超大配置、无效 signer / team 和重复记录。不在仓库保存真实批准记录。Installer 只登记当前用户、同团队的 OCU 原生 CLI / app agent 与 Guardian；本阶段不开放任意第三方 agent 登记。
- 批准记录绑定 UID、角色、signing identifier 和 Team ID；角色按连接 endpoint 选择，不取请求 payload。批准 peer 必须启用 hardened runtime，并拒绝 get-task-allow、禁用 Library Validation、允许 DYLD 环境注入或 unsigned executable memory 等 entitlement。Developer ID 签名的 self-test 验证正确 signer / role 成功及错误 signer / role 拒绝；这不代替真实 unlock 链路验证。
- `LockedUsePermitRegistry` 使用 SecRandomCopyBytes 生成 32-byte nonce，绑定 connection UUID、attempt UUID、UID、audit session，5 秒过期，单次消费，断开撤销，重放拒绝。最多 32 个 pending permit；单个 registry 最多保存 4096 个 retired attempt；只有上一租约完全释放并可开始新租约时，Broker 才创建新 registry epoch。旧 lease ID / nonce 不能跨越 epoch。该 registry 不验证插件身份，调用它之前必须先认证 Apple SecurityAgent peer。

Broker 重启后，如果恢复记录表明从未发出解锁授权，且内核确认记录里的 owner、Guardian 和 watchdog 均已退出，Broker 会清理这次租约的恢复记录并回到空闲。普通桌面操作仍检查当前会话是否已解锁。曾发出授权或缺少进程退出证据的租约继续走原来的重锁和排空流程。

## Authorization 插件实验

先在普通用户进程内验证 ABI，不注册系统 right：

```sh
./scripts/build-locked-use-plugin.sh
```

产物全部在 `.build/locked-use/`：插件 bundle、ABI tests、`authorization-probe`。该插件仅支持 `preflight`，每次 `MechanismInvoke` 都返回 `kAuthorizationResultDeny`；不读取任何认证上下文，不设置密码，不执行解锁。未知机制（包括 `allow`）不能创建。

离线 `dlopen` 与 codesign 验证不证明 SecurityAgent 的 Library Validation 可以加载插件。要测试实际系统加载，需要先用自己的 Developer ID Application identity 签名：

```sh
./scripts/build-locked-use-plugin.sh --identity 'Developer ID Application: <your identity>'
sudo ./scripts/manage-locked-use-probe.sh install
.build/locked-use/authorization-probe
/usr/bin/log show --last 2m --style compact --predicate 'eventMessage CONTAINS "OpenComputerUseAuthorizationProbe invoked"'
sudo ./scripts/manage-locked-use-probe.sh uninstall
```

安装脚本是独立实验入口，不是 `ocu locked-use enable`。只注册 `dev.opencomputeruse.locked-use.preflight`，只安装自己的 bundle，不修改 `system.login.screensaver`；拒绝覆盖已有 right / bundle。注册失败会移除本次复制的 bundle。卸载前核对 right 和 bundle 仍属于实验，再删除 right、bundle 与自己的系统 staged 副本。脚本要求 root 和 Developer ID 签名，拒绝 ad-hoc 安装。不关闭 SIP / Library Validation，也不承诺仅签名即可通过系统加载限制。

探针预期返回 `errAuthorizationDenied`。**denied 也可能来自插件加载失败**，只有实际机制的固定日志 marker 才是加载证据。探针不请求 screensaver right；输出 `sessionUnlockRequested=false` 指本探针没有请求解锁，不是对桌面状态的观测。实验日志不得加入用户名、密码、Keychain 内容或授权上下文。

## 测试前清理其他插件

若诊断显示 `CodexComputerUseAuthorizationPlugin.bundle`，它是 Codex / ChatGPT 的 Locked Use Authorization 插件。优先在应用 **Settings → Computer Use → Locked use** 中关闭该功能，然后用只读命令核对：

```sh
security authorizationdb read system.login.screensaver
ls /Library/Security/SecurityAgentPlugins
```

正常清理后不应再有 `com.openai.sky.CUAService.AuthorizationPlugin.remote` 引用和 Codex 插件 bundle。`StagedPlugins` 目录本身不代表它仍启用。不要只删除 bundle，也不要把整个 screensaver right 覆盖成固定模板：其他认证产品可能也有规则。关闭后若残留，先保存规则并诊断其所有者，不在此实验中自动删除第三方组件。

## 当前实机结果

在 Apple Silicon / macOS 26.5.1 上，Developer ID 签名的独立 probe 已实际安装、调用和卸载。4 次 AuthorizationCopyRights 都返回预期 denied；SecurityAgentHelper 的固定机制日志证明插件实际执行。首次加载曾记录 platform-binary Library Validation 错误，随后同一 helper 仍执行了机制，不能仅据那条错误判定全部调用失败，也不能只凭 denied 推断加载成功。

实验后诊断 right、原 bundle 和自身 StagedPlugins 副本均已移除，screensaver right 没有变化。没有尝试真实解锁或读取用户 Keychain 项，因此这些结果不证明真实 loginwindow unlock / Keychain 保持、完整 guardian 或系统版本兼容性已通过。

## 生产 backend 的开放门槛

1. 实际 SecurityAgent 加载、正常认证不被阻塞；保留 `use-login-window-ui`。
2. 真正 loginwindow 解锁事务可由短期许可驱动；AuthorizationCopyRights 成功本身不算桌面解锁。
3. 解锁过渡、所有显示器与 Spaces、热插拔及保护进程退出时的实测遮蔽与重锁行为；软件截图无法验证物理显示泄漏。
4. AX / ScreenCaptureKit 可以捕获遮挡的目标窗口，fixture 点击 / 输入后 AX 和画面验证一致。
5. 普通密码 / Touch ID 解锁，以及 login / Data Protection Keychain 不受破坏；用测试项验证，不读取用户凭据，不做密码重置或 Keychain 修复。
6. 认证 IPC 来源、客户端登记、许可重放和撤销、并发所有者、宿主断开与接管抑制全部通过。

测试账户有助于隔离业务数据，但 Authorization 数据库和插件是系统级的；账户隔离不等同于系统隔离。实际认证实验要有可恢复的机器 / VM 和管理员操作路径。

## 参考

- [Apple Authorization 插件](https://developer.apple.com/documentation/security/extending-authorization-services-with-plug-ins)
- [AuthorizationCopyRights](https://developer.apple.com/documentation/security/authorizationcopyrights(_:_:_:_:_:))
- [NullAuthPlugin ABI 示例](https://developer.apple.com/library/archive/samplecode/NullAuthPlugin/Introduction/Intro.html)
- [Apple DTS 关于 Data Protection Keychain 的已知问题](https://developer.apple.com/forums/thread/796487)：FB13128730，没有公开可靠 workaround，不能假定本系统已修复。
- [官方 Computer Use / Locked Use 设置](https://learn.chatgpt.com/docs/computer-use)
- [DispatchShield](https://github.com/VenusOne-Lee/DispatchShield)：已解锁桌面遮蔽参考，不是锁屏自动解锁实现。
- [trycua Authorization 插件讨论](https://github.com/trycua/cua/issues/1744)：方案参考，不是完成链路的证据。


## 管理员安装与 OCU 接入（待实机验证）

先构建、签名组件，再将它们嵌入同一签名团队的开发 app：

```sh
scripts/build-locked-use-components.sh --identity 'Developer ID Application: <your identity>'
OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=1 scripts/build-open-computer-use-app.sh debug
'dist/Open Computer Use (Dev).app/Contents/MacOS/OpenComputerUse' locked-use settings
```

安装 UI 将 artifacts 复制到 root 保护的 staging，验证签名 Installer 后才执行它。Installer 再验证全部组件、签名团队、hardened runtime、无注入 entitlement 和 root 目录 / ACL；登记当前用户的原生 CLI client、app agent 与 Guardian。当前登记范围是本 app 的原生客户端，不能将其描述为已认证 Node / Codex 父进程。原生客户端 socket 通过 SCM_RIGHTS 转交，Broker 仅检验内核 peer，不读该 socket 的业务数据；UID / audit session 必须与 agent 一致。规则备份先写入 root 目录；只为现有 OR policy 增加独立 remote branch，保留原生 / 第三方 fallback。Installer 并发操作用独立 flock 排斥。

`locked-use enable` 安装生产 profile，缺少匹配实测证据时不能自动解锁。仅开发实测显式使用 `locked-use enable`；它通过管理员安装的 launchd profile 开放验证事务，不等于生产验证通过。`locked-use disable` 先冻结 Broker 的新租约，只有 idle / awaitingManualUnlock 时恢复匹配的原规则、停止服务并移除自身插件及 staged 副本；第三方策略改变时拒绝覆盖。安装失败会保留 recovery plan，`locked-use recover` 可恢复部分安装，但只有实例锁和 root journal 证明旧保护已释放时才移除组件；未排空的崩溃事务必须先恢复 Broker。此路径仍待系统验证。

普通 app-agent GUI 调用在完成登录的锁定 console session 请求租约；库存 / 协议查询不触发解锁。Guardian 从锁屏启动，通过私有 inherited pipe 接收 challenge；准备覆盖、tap、硬件活动 monitor 与独立 watchdog 后，收到 root 的一次 requestUnlock，调用公开 IOPMAssertionDeclareUserActivity 唤醒显示器。随后等待系统发起 screensaver 认证事务，remote 插件显式 SetResult 放行已消费的一次性许可。唤醒成功不证明事务已开始或会话已解锁；3 秒预算内重试完整 AX 发布，然后在已验证 Apple 签名的 loginwindow 上遍历 AXChildren（深度 ≤8、最多 300 节点、0.75 秒扫描预算），优先匹配 `UserPasswordTextField`，回退 `FocusedUser`。完整扫描且候选唯一时空字符串写入，不读取字段内容。仅 fallback 使用一次窗口限定、双过滤器能力验证的点击；点击后重新查找真正的密码框。管理员验证 profile 才允许在密码框空写成功、明确声明支持 AXConfirm 时执行一次确认，采用 Root hello 的实验开关；生产及旧协议缺少开关时不执行。没有全局键盘合成。空写、点击、AXConfirm 返回均不能替代许可消费与真实同会话解锁证据。两套保护分别持有有界 display-sleep assertion，退出 / 最大租约期限时由 powerd 释放。原生会话真实 unlocked 且根服务确认全部保护健康后，才启用 GUI dispatch。各输入 / AX mutation / snapshot session gate 再向根服务核验当前连接。其他连接用只读 observer endpoint 检查租约，不能借用临时解锁的桌面。Secure Event Input 下 IOHID 活动交付尚待实机验证。参考方案的核对与尚未证实的系统行为见 [解锁入口复核](references/macos-locked-use-solution-review.md)。

开发 Keychain 检查仅使用 `ocu/locked-use/keychain/prepare`、`verify`、`cleanup` 等原生 MCP 方法。为 login 和 Data Protection Keychain 分别创建本项目 UUID / 随机值测试项，verify 禁止弹出认证 UI，返回布尔结果与 OSStatus；不枚举、读取或修改已有用户项目。cleanup 失败会保留对象以便正常解锁后重试。独立 native fixture 与 FixtureBridge 无关，后续闭环必须走真实 AX 和 ScreenCaptureKit。


## 崩溃恢复与双进程保护

Broker 在回复授权 / active 之前，把同一 kernel boot epoch 的旧租约、内核 peer token / code hash、解锁观察、动作排空与保护 ACK 写入 root 的 `lease-recovery.json` 并 fsync 文件和目录。私密记录从创建到原子发布均为 0600，移除继承的 extended ACL；读取时也拒绝公开权限或 ACL。**不保存、不恢复授权 permit nonce。** 同一 boot 的服务重启只继续旧事务的排空和重锁，要求正常手动解锁后才解除抑制。原进程重连必须匹配已记录的完整内核 token 与签名哈希；原生 CLI 死亡后恢复连接只能用于清理，不能继续动作。kernel reboot 会摧毁原 GUI / 排队认证事务，属于新的会话 epoch。

独立 watchdog 经私有 pipe 注册到 root，持有另一个进程的备用遮罩、过滤 tap 和硬件活动 monitor；Broker 要求两套保护健康且心跳新鲜。Guardian 主线程卡死或进程死亡时，备用窗口仍可保持遮蔽，watchdog 的 root RPC 在另一个队列执行，不能拖延 inherited heartbeat 的重锁期限。主 Guardian / watchdog 都要在原会话已锁定、事务与动作已排空后释放自己的保护并向 root 回报 ACK。新的租约和卸载都等待这些 ACK。软件窗口仍不构成系统级原子热插拔 / 所有 secure overlay / 双进程同时死亡的零泄漏证明；需针对目标系统验证。

Broker 在独立 policy 队列每秒读取本项目认证策略，主队列不等待 AuthorizationRightGet，以免阻塞正在等待 Broker 的授权机制和恢复通信。签发 / 消费许可必须有不足 2 秒的有效观察；待定 / 过期 / 失败观察拒绝新许可，失败或过期后本 epoch 撤销租约但保留恢复通道。读取时间从开始读取时计，慢请求的迟到结果不能视为新鲜策略。不会自动覆盖第三方的新规则。

## 专用真实 GUI / Keychain 验证

```sh
# 普通已解锁状态，先验证独立测试项与真实 AX / SCK。
python3 scripts/run-locked-use-native-validation.py --prepare-only --legacy-only
python3 scripts/run-locked-use-native-validation.py --unlocked-fixture-test --legacy-only

# 管理员安装验证 profile 后，由用户配合锁屏测试。
python3 scripts/run-locked-use-native-validation.py --confirm-lock-test
```

控制器保持同一原生 MCP 连接：正常解锁时创建本项目 UUID 的测试项，从真实锁屏调用固定 native validation，受保护解锁后只对签名的 `OCU Lock Demo` 执行 AXPress，检查计数器变化和前后真实 SCK 图片哈希，再读取自己的测试项。图片与 secret 只在内存；输出只有结果。结束后发送 turn-ended、观察重锁，用户正常解锁并输入 `continue`，再验证 / 清理测试项。带 `--wait-for-manual-unlock` 时控制器直接观测真实会话解锁，不需要 stdin 确认；等待本身不代表通过。备用遮罩可以通过签名 Guardian 的 `--watchdog-surface-self-test` 单独检查，不请求锁屏或解锁。任何失败都不杀 Guardian / watchdog，也不凭旧锁屏拆除保护。连接退出时无法删除的自有项目会留在 app agent 内重试正常解锁后的清理；进程死亡会丢失内存清理对象，应保留监督式测试连接直到 cleanup 完成。

Data Protection Keychain 使用受限 entitlement，需要为该 OCU bundle 匹配的 macOS Developer ID provisioning profile：

```sh
OPEN_COMPUTER_USE_PROVISIONING_PROFILE='<profile path>' \
OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=1 scripts/build-open-computer-use-app.sh debug
```

构建只从 profile 提取当前 app 自己的 App ID / Keychain group，拒绝过期、其他平台、其他 app 和带 debugging entitlement 的 profile；macOS 在进程启动时仍独立验证签名 / profile。详情见 [Apple TN3137](https://developer.apple.com/documentation/Technotes/tn3137-on-mac-keychains)。`--legacy-only` 是明确缩小范围的开发检查，不能产出生产验证证据；缺少 profile 时不能把 Data Protection 检查记为通过。

签名 native agent 的固定测试全部通过后才向 root 提交验证回报。Broker 保存组件 / OS 哈希及真实重锁、双方保护释放、手动解锁后的 Keychain 验证到 `validation-report.json`。`locked-use certify` 要求用户确认物理屏幕、Secure Input 键鼠接管、进程 / 服务故障、显示器变化以及正常密码 / Touch ID 的实测结果，再通过系统管理员认证；Installer 还独立检查完整 root 记录和当前哈希，并冻结 / 重启服务为生产 profile。此入口尚未实机通过，不能将已实现入口描述为验证完成。macOS 或组件升级会使旧证据失效；停用 / 恢复原策略后重装新组件并重新验证。

app bundle 含每次构建唯一的标识，app agent 在启动时固定捕获该标识和启动时间，避免懒初始化把旧进程误判为新构建。MCP 获取租约或验证失败仍返回对应 JSON-RPC id 的错误；不会让调用方一直等待响应。JS reset / timeout / turn-ended 关闭旧 native epoch；旧 Worker 的排队请求被丢弃，下次请求启动新的 native MCP，不重放失败的 GUI 请求。

失败恢复增加独立于 RPC / AppKit 队列的 agent deadline：独立进程 deadline 跟随已认证 Root 的启动截止 + 现有 RPC 排空余量 2 秒；默认启动上限 8 秒，显式验证 profile 的总待命上限 20 秒，准备双保护仍最多 8 秒；进入停止 / 清理或 Broker 轮询失败后最多 5 秒，重试只能缩短、不能延长已有期限。期限到达时 agent 结束自身进程，不杀用户应用或保护进程。Broker 仍须通过原进程退出、解锁工作排空和实际锁定证据决定释放双遮罩；这个期限是停止动作的上限，**不等于系统恢复可登录的实测上限**。已观测到原会话锁定时，主 / 备用保护不重复调用锁屏 SPI；等待排空仍保留遮罩。

真实实验曾出现 Broker 清理通信超时、保护持续数分钟并干扰用户正常解锁。已安全卸载验证组件并恢复原认证规则；自动解锁没有通过。下一轮锁屏测试之前，必须先验证独立 deadline、进程退出到保护释放的故障链路，以及 Broker 清理通信时延，不能继续用长时间循环锁屏定位问题。`OCUGuardian --recovery-deadline-self-test` 只阻塞自己的主线程、用独立计时结束自身进程，预期退出码 70；不调用锁屏、认证或显示遮罩。

恢复专项入口 `python3 scripts/run-locked-use-native-validation.py --confirm-recovery-test` 仅供已安装验证 profile 的人工测试：真实锁屏、创建双保护，然后由 Broker 在签发许可前直接终止事务；要求 root 回报两个保护确曾就绪，再等待实际锁定、动作排空和两个保护退出 ACK；准备失败后清理成功不算双保护恢复通过。生产 profile 拒绝此入口。输出恢复耗时与布尔结果，不创建 Keychain 项、不执行 GUI 动作，不作为自动解锁通过的证据。

`--confirm-wake-test` 只验证受保护的实际解锁并立即发送 turn-ended / 观察重锁，不操作 GUI、不捕获窗口、不访问 Keychain；它也不能生成完整生产验证证据。

快速完整开发检查：

```sh
python3 scripts/run-locked-use-native-validation.py --confirm-lock-test --legacy-only --fast --wait-for-manual-unlock
```

每轮锁屏前 `ocu/locked-use/ready` 必须观察正常解锁且双保护已释放，避免新连接沿用失败事务。`--fast` 在真实 AX / SCK 验证后立即重锁并等待双方释放 ACK，不额外保持租约。控制器将阶段耗时、固定返回码和通过结果写到 `.build/locked-use/reports/` 的私有 JSON（文件 0600）；只保留白名单诊断字段，不保存原始日志、截图、字段内容或密码。该报告与生产认证证据分开，不能开放生产。

认证宿主诊断可在正常解锁、验证 profile 已安装时独立运行，无需再锁屏：

```sh
xcrun swiftc -framework Security -framework CoreGraphics experiments/LockedUse/Sources/RemoteVerificationProbe.swift -o .build/locked-use/remote-verification-probe
.build/locked-use/remote-verification-probe
```

它仅评估本项目独立 remote right，不创建租约、不请求 screensaver right、不提交密码；无租约时预期 denied。通过仍须核对实际机制日志、Broker 签名返回码和无许可 claim 被拒绝，不能仅凭 denied 判定成功。快速测试失败后，控制器先检查双保护已释放；指定自动观测手动解锁时，随后等待正常登录并重试隔离测试项清理，再保存报告，以纳入手动认证阶段的诊断。

授权插件在 macOS 14.4+ 使用 `SecTaskValidateForRequirement` 的内核进程检查，要求正确 signing ID / Team、Developer ID 验证类别、动态有效签名、hardened runtime 与 Library Validation，拒绝危险 entitlement。旧系统保留 SecCode；现代检查失败不回退。构建流程含独立签名的正确 / 错误 ID / ad hoc / get-task-allow 反例，不安装这些测试 executable。单轮日志分别记录连接、task verification、claim、consume、SetResult、阶段和停止原因；authd / loginwindow / 认证宿主原始字段仅在内存中归一化为固定诊断枚举，不保存账户或 caller。

共享遮罩采用不激活的 NSPanel（borderless + nonactivatingPanel、关闭 hidesOnDeactivate；主遮罩位于 CGShieldingWindowLevel + 1，备用低一层），避免普通窗口参与登录切换的缩放；实际 WindowServer bounds 与 CGDisplayBounds 均按 Quartz 全局坐标检查完整包含，允许大于屏幕的遮罩；任何未覆盖边缘或无效矩形仍拒绝，layer / owner / alpha / 可见性 / 拓扑检查继续保留，动画时覆盖不合格也必须重锁。


锁屏前实时采集认证诊断，私有报告 schema 2 区分 authorizing 保护待命阶段与之后的手动恢复；permitIssuedObservedAt 单独记录实际许可签发。日志活动、机制 Allow 和实际自动解锁是不同证据；缺失日志不证明事务或 helper 不存在。采集器最长 150 秒、最多 2000 条固定诊断、单条原始记录最多 64 KiB，不保存原始字段；不可用时不改变保护或授权。仅需正常桌面观察时可执行：

```sh
python3 scripts/run-locked-use-native-validation.py --observe-auth-only --observe-seconds 5
```

该入口不需要安装验证 profile，不锁屏、不请求认证、不创建租约。当前验证实现为有界完整 AX 发布重试、唯一字段空字符串写入和一次窗口限定 session-stage 点击（双过滤器的一次性私有能力）；不再执行 AXPress / Return。点击只是一项投递实验，不能据此认定认证事务或自动解锁成功。详见 [认证时序复核](references/macos-locked-use-auth-transaction-timing-review.md)。

`--confirm-wake-test` / `--confirm-recovery-test` 配合 `--wait-for-manual-unlock` 时，双方释放后继续最多 60 秒只读观察正常手动登录，不保留遮罩、不启动 GUI 验证。实时与历史日志可能重复报告同一阶段，重复 authorizing 不创建新许可窗口。

原始客户端的 SCM_RIGHTS socket 在身份复核前先检查进程退出与 EOF；断开立即拒绝，健康连接仍完整重验内核身份和签名。此检查不替代签名验证，也不保证所有 Security.framework 查询都有界；恢复后的 readiness 必须实际通过才启动下一次锁屏。

双保护就绪的 authorizing 现在是保护待命，不等于已有许可。首次合法 pluginClaim 才签发许可，截止取 claim 后 5 秒与本轮 Root 启动截止的较早值；默认等待最多 8 秒，显式验证 profile 最多 20 秒，不因唤醒、AX 探测、重复 claim 或手动登录延长。控制器关闭已退出 native 连接时容忍 BrokenPipeError，仍保存诊断报告。

会话入口事件实验使用 NSEvent.windowNumber，并通过 Guardian → watchdog 继承管道共享独立随机点击标记。双过滤器均验证来源、顺序、同目标 / 窗口 / 坐标和短时限，只放行一次 down/up；真实硬件活动不会获得豁免。能力不是认证许可，不能授权 SetResult；认证仍须插件 claim / consume 和原会话解锁观察。原 annotated-stage 实验即使 queued 成功也没有自动解锁；NSEvent 版本曾出现 RPC 超时，timer 阶段及慢签名检查已新增诊断。

Root 通过 IPC 返回绝对 uptime 截止，原生 agent 校验其有限且不超过 20 秒，并使用同一截止控制等待和独立退出余量；客户端不能延长 Root 期限。启动截止保留在日志与协议中，产品遮罩不显示认证倒计时。20 秒仅为验证 profile 的有界待命，不是 20 秒授权许可；常驻服务或 socket 生命周期也不是放行期限。参考事件还显式编码窗口内坐标和鼠标 subtype 3，本项目复用现有 SkyLight 编码器，缺符号时不投递。这是私有鼠标编码，不是解锁 / 认证 API。点击后只在原 3 秒唤醒限额内重新查找密码字段（最多额外 1.5 秒），不复用旧 AX 元素、不发第二次点击、不提交密码 / Return。

- HID 单变量实验：用户授权尝试仅将受控 down/up 投递从 session 改到 HID；复用已认证 Root 的验证 profile 开关，生产 / 旧协议保持 session。事件字段、双会话过滤的一次性能力、硬件活动接管、空写 + 单次支持确认、20 秒截止不变。新增固定 clickTap 枚举日志；此改动不保证被系统视作真实硬件或启动认证，待实测。

- 确认超时修正：扫描给候选 AX 对象设置的 50ms 消息超时会被后续 action 沿用。Apple AXUIElementPerformAction 文档明确 cannotComplete 可能源自超时 / 模态处理，但不能仅据错误码确认因果或动作未执行。session 轮先前已执行同一确认并返回成功，不是 HID 轮首次加入。验证版为单次确认独立设置最多 2 秒、裁剪到原 3 秒 UI 请求截止的超时，结束恢复扫描超时；记录配置结果、实际调用开始、调用耗时与结果。不自动重试，避免无法确认是否执行时重复提交。Root 总 20 秒截止、取消 / 排空与双保护不变。待实测比较。

## 无遮罩解锁诊断（仅管理员验证 profile）

用户明确要求拆开解锁与保护问题后，新增独立 `LockedUseUnshieldedDiagnostic`，不复用生产 guardsReady 或 GUI action 状态机。Root 只接受管理员验证 profile 下、已批准签名 UI 探针的原锁定 UID / audit session；诊断总期限 20 秒，插件首次同会话 claim 才签发最多 5 秒且裁剪到原截止的一次性许可。无守护健康 / 心跳条件，也不伪造覆盖证据。断开、认证策略失效、期限到达或许可过期撤销后不能恢复。所有应用 action、生产验证 / promotion 与正常租约入口在诊断活跃时拒绝；重启不恢复任何诊断许可。

签名工具的独立 `--unshielded-unlock-diagnostic --confirm-visible-desktop-test` 入口复用 `LockScreenInteractor`，没有构造 DisplayGuardian、遮罩、输入 tap、硬件 monitor 或 child watchdog。因此桌面若被解锁会实际可见，不能视为生产 Locked Use。它只观察原会话解锁并立即请求 / 确认重锁，最后向 Root 结束诊断；结果与私有报告始终 productionEvidenceEligible=false，不访问应用窗口 / ScreenCaptureKit / Keychain。外部控制器入口为：

```sh
python3 scripts/run-locked-use-unshielded-diagnostic.py --confirm-visible-desktop-test
```

该入口针对人为配合的单次故障定位，没有完整保护路径的进程崩溃与遮蔽保证。实现回归覆盖生产 profile 拒绝、原 session / role 绑定、跨 audit session / 重复 claim / 许可重放、晚到许可裁剪、5 秒过期 / 20 秒过期 / 取消不可重启、非原会话结束与 GUI / 生产验证拒绝。当前 Swift 266 项（1 跳过、0 失败）通过，真实诊断待安装运行。


无遮罩诊断的实际结果：首轮存在 Touch ID 手动认证与许可窗口重叠，不算自动解锁；随后不手动介入的 20 秒复测没有解锁或许可消费。控制器按原生 uptime 记录事件，并标记许可窗口内的 Touch ID match。AXConfirm 返回 success、插件放行和自动解锁必须分别验证，不能相互替代。


独立无遮罩诊断现用固定 Return HID 按下 / 松开替代 AXConfirm，要求唯一且已聚焦、可写的密码框及签名 / 原锁定会话再次校验，只发送一次。该键盘实验尚未实测，不在受保护解锁路径启用；保护过滤器当前没有键盘许可。派发成功仅表示排队，必须另外观察 loginwindow 提交、插件许可与原会话实际解锁。


Return 独立无遮罩诊断已实测跑通：空写 / 点击后对聚焦的唯一密码框发送单对 Return，loginwindow 提交认证、OCU 插件消费许可、原会话解锁后立即重锁，报告中无 Touch ID match。它仅证明本轮无保护的解锁 / 重锁链，不替代受保护 GUI / 捕获 / 故障验收。认证规则一度变更后 Broker 会持续关闭该进程周期的解锁接受能力；恢复规则本身不能重开，须完整复核后经管理员重启服务。


受保护管理员验证 profile 现支持独立 Return 一次性能力：主 / watchdog 两个 session tap 必须各自验证原锁定会话、来源 PID 和随机 tag、固定 keyCode 36、无修饰 / repeat、5 秒有效期与 250ms 成对时限。实际派发前还需唯一密码框焦点、空写与 Apple loginwindow 签名复查。任何硬件接管或停止均撤销；默认生产 profile 仍不签发键盘能力。完整 AX / SCK / 重锁已在管理员验证 profile 的 legacy-only 轮通过；不作为生产 promotion 证据。


遮罩采用居中 1.5× 不透明面板，为 loginwindow 解锁动画的缩放留出实际不透明覆盖余量；健康检查不容忍任何实际未覆盖边缘，仍严格比较 WindowServer 实际边界与显示器。受保护首轮已进入插件放行，但动画缩小遮罩导致 guardLost，overscan 修正版随后通过真实受保护 GUI / SCK / 重锁闭环，未发生覆盖失败。


overscan 修正版首次完整实测通过：Return → loginwindow 认证 → 插件一次性许可 → 原会话实际解锁 → 双保护健康下 AX 修改固定 fixture 且 SCK 图像变化 → 重锁 → 双保护释放。手动正常解锁后的自有隔离 legacy Keychain 项验证 / 清理通过。物理屏幕持续覆盖待现场确认；本轮未覆盖 Data Protection Keychain、Secure Input 硬件接管和组件死亡 / 显示器变化，因此 productionEvidenceEligible=false，生产保持关闭，尚未合并。


停留计时复测：--fast 会将停留设为 0，因此首轮双保护就绪至释放约 3.68 秒。使用 --hold-seconds 5 后，AX / SCK 通过再实际停留 5.002 秒，随后 turnEnded 正常重锁和双保护释放；双保护就绪至释放约 7.78 秒。控制器现输出停留开始 / 结束及单调时钟实际耗时；现场观察不应把初始“5 秒后锁屏”提示当作遮罩停留承诺。


主 / watchdog 遮罩使用同一固定展示：`Open Computer Use is Using Your Mac` 与 `Press any key or click to unlock`。认证、操作和排空不切换文字，停止后冻结最后一帧。共享视图从各屏幕的 NSWorkspace 壁纸文件读取并模糊处理，只查询当前本地账户的 OpenDirectory 头像，叠加 bundle 内的 OCU 图标；不截图桌面，不读密码或 Keychain。资源缺失时使用不透明备用背景 / 默认头像，窗口仍为 alpha=1 的 1.5× overscan，覆盖检查和重锁呈现屏障保持不变。隔离诊断可显示额外说明；15 秒不锁屏 preview 的倒计时只记录在日志中。


用户现场确认显示状态修正版整体正常、两块物理屏幕覆盖稳定；退出前轻微文字跳动另以冻结最后一帧修正，待现场复测。


撤罩另需主 / watchdog 各自确认锁屏呈现屏障：原会话 locked、已排空，并观察到经 Apple 签名验证的 loginwindow 不透明屏蔽层窗口覆盖所有活动显示器，几何 / 拓扑连续稳定至少 1 秒。仅会话锁定不再允许释放。该元数据条件不是 compositor 原子交接证明，仍须现场验证；缺少证据时继续保留保护，不重新发送锁屏请求去打断正常恢复登录。


撤罩屏障首次实测因将 loginwindow layer 与极高 CGShieldingWindowLevel 比较而永久等待，已纠正为 screenSaverWindow 级别。新增独立本地恢复：Root 排空后已观察原会话锁定且真实 IOHID 活动发生，才把输入交回系统 loginwindow；仍维持遮蔽，直到用户实际解锁同一会话才释放，不反复重锁。此恢复不签发远程 GUI 许可；软件超时和模拟输入不能启动它。新呈现屏障 / 恢复仍待现场验收，不能视为生产可用。

### 遮罩外观渲染

签名 Guardian 的 `--render-shield <output.png>` 在当前主屏壁纸和头像上离屏渲染外观，不创建保护租约、输入 tap 或锁屏请求。输出可能包含用户头像及壁纸，应仅留在忽略的本地构建目录，不上传或纳入版本控制。动态 / 视频壁纸无法解码静态帧时使用备用背景。`--shield-preview` 则对全部显示器执行 15 秒覆盖检查，Esc 可提前结束，无自动解锁 / 锁定动作。

品牌遮罩物理双屏闭环已现场通过：插件一次性放行、原会话自动解锁、遮罩下 AX/SCK 图像变化、保持 5.005 秒、重锁与双保护撤罩、正常手动解锁和隔离数据清理；用户确认无桌面闪现。主进程在创建窗口前完成 AppKit 初始化，只在保护准备完成后运行 live heartbeat，原有覆盖与超时要求保持。额外虚拟屏的窗口偏移曾导致安全中止，本轮由用户移除后不再纳入验收，不能据此宣称虚拟屏兼容。该轮 legacy-only 不生成生产资格。

录屏演示可在完整验证命令上增加 `--keep-fixture`。仅在验证成功、手动解锁及隔离数据清理完成后保留 Increment Counter 原生窗口，便于查看实际计数；Broker 租约、保护窗口和 agent 连接按原流程结束。失败仍关闭测试目标。录屏后请手动退出该测试 app，再启动下一轮，避免多个同 bundle 目标影响 AX 定位。该开关不延长受保护操作时间，也不生成生产资格。

```sh
python3 scripts/run-locked-use-native-validation.py --confirm-lock-test --legacy-only --hold-seconds 5 --wait-for-manual-unlock --keep-fixture
```

退出 ACK 由 main / watchdog 在各自真实撤罩后，经同一签名与 audit-token 的恢复连接提交，最多 3 次并检查回复；不以窗口进程死亡冒充 ACK。周期报告的 IPC 失败不再跳过 terminal 确认。控制器最多等待 8 秒观测 Root 的双 ACK，此等待不生成许可或代替呈现屏障。演示的 `--keep-fixture` 目标采用独立进程 session 和空 stdin，因此 runner 结束不带走原有计数窗口；已实测脚本退出后只读 AX 仍见 `Counter: 1`。


## 独立 main PR 的集成边界

Locked Use 从 awesome-extension 单独提取，不依赖该分支的虚拟工作区、电源模块或 AX diff。main 的普通 `get_app_state` 返回完整树，原生固定验证继续读取完整 Counter；未来引入增量输出时必须显式请求完整快照。失败后控制器先发送 turn-ended 再等待双保护释放。main 的 sky_click / sky_key 原生投递及菜单动作也执行会话 / 租约检查；租约内窗口捕获明确走 ScreenCaptureKit，普通非租约捕获沿用 main 的硬件截图优先路径。MCP 断开仍执行 endSession 恢复 main 的 agent display 和窗口 occlusion 状态。

该独立 PR 的验证为回归测试、签名构建和 ABI 检查；先前双物理屏实测是 awesome-extension 的证据，不代表本次分支重新进行真实锁屏验收。生产 backend 继续关闭。


## 组件命名与正式构建

| 组件 | 正式构建 | 开发构建 |
| --- | --- | --- |
| 主 App | Open Computer Use.app | Open Computer Use (Dev).app |
| 遮罩 App | OCU Guardian.app | OCU Guardian (Dev).app |
| root 服务 | OCULockService | OCULockService |
| 安装工具 | OCULockInstaller | OCULockInstaller |
| 授权插件 | OCULockAuth.bundle | OCULockAuth.bundle |

Watchdog 是 OCUGuardian 的另一进程模式，不新增 App。OCU Lock Demo (Dev).app 和 OCULockProbe.bundle 仅供开发验证，正式 App 不打包这两项。正式组件构建输出 components-release，开发仍输出 components；主 App 按自身配置选择对应组件，内嵌及系统安装的 Guardian 路径固定为 OCU Guardian.app，plist 中的显示名称保留配置差异。

签名 ID、launchd Label 与 remote right 保持已有内部标识；授权机制同步改为 OCULockAuth:remote。Guardian 的内部签名 ID 保留原标识，即使正式显示名称不带 Dev。此命名调整不开放生产后端。

```sh
scripts/build-locked-use-components.sh --identity "$IDENTITY" --configuration release
OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=1 OPEN_COMPUTER_USE_CODESIGN_MODE=identity \
OPEN_COMPUTER_USE_CODESIGN_IDENTITY="$IDENTITY" scripts/build-open-computer-use-app.sh release
```

已有旧验证安装先在正常解锁、保护已结束时执行新 App 的 `locked-use disable`；新 App 会校验并调用旧安装中的签名 installer 完成其原始卸载，再执行新版本 enable。安装器发现旧插件残留时拒绝安装，不直接改名在用插件或自动替换认证链。旧版本生产资格不能复用，新制品须重新验证。
