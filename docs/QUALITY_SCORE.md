# 质量评分

## 评分标准

- `A`：覆盖完整、行为稳定、文档清楚、运行风险低。
- `B`：整体可接受，但还有明确短板。
- `C`：能用，但需要针对性补强。
- `D`：脆弱、缺少规范，或很多行为尚未定义。

## 当前水位

| 区域 | 评分 | 原因 | 下一步 |
| --- | --- | --- | --- |
| 产品面 | B | 已经有 Swift 本地 `computer-use` MCP server、默认 app 模式权限引导，以及共享的 9 个核心 tools；macOS 另有 query、select_text 和纯文本剪贴板读写，JS 可调用。 | 继续收敛复杂 AX 场景下的 state rendering 细节、权限 UI 和更清晰的用户错误提示。 |
| Windows runtime | C | 已新增独立 Go `.exe`，通过 Windows UI Automation + Win32 window message 暴露同样 9 个 tools、MCP server 和 `call --calls`；默认不再自动启动 app、执行 `SetFocus`，或让 `type_text` 走可能抢前台的 UIA text fallback；截图会过滤隐藏、最小化、cloaked、离屏和退化窗口，并在 Go 层复核 PNG，但整体仍是功能性第一版。 | 维护 WPF 观察 / 输入 / 截图边界 fixture 和 Windows PR smoke，扩展更多工具与 toolkit；补 installer/signing，以及更原生的 Go UIA 实现或更稳定的 bridge。 |
| Linux runtime | C | 已新增独立 Go binary，通过 Python GI / AT-SPI2 暴露同样 9 个 tools、MCP server 和 `call --calls`；Ubuntu GNOME VM 已跑通 `list_apps`、MCP tools list 和 Text Editor 8-tool sequence，并已接入 npm bundled artifact 分发，但截图在 GNOME Wayland 下仍只能 best-effort，coordinate input 也不是通用后台模型。 | 扩展已有的隔离 GTK 动作回读 smoke，补完整工具覆盖、portal/compositor screenshot 路径，以及更原生的 Go D-Bus/libatspi bridge。 |
| macOS Locked Use | D | 已有签名 Broker / 插件、双进程保护、原生租约与恢复入口，离线和遮罩 rehearsal 有回归；安装恢复和无许可双保护释放已实测，独立无遮罩 Return 解锁 / 重锁已实测，受保护自动解锁 / AX / SCK / 重锁及隔离 legacy Keychain 已有一轮实测通过，完整会话认证状态 / 故障链路尚未通过实测；正常启用改为管理员 enable 与签名校验，普通 enable / 正常 MCP 的完整 GUI 闭环已实测。 | 物理覆盖已确认，继续完成 Data Protection / 会话认证状态、Secure Input / 崩溃 / 显示器故障回归及正式发布制品检查。 |
| 架构文档 | B | 顶层结构、fixture bridge、app 模式和验证路径已经落文档。 | 后续补 release artifact、code signing / notarization 和 host 集成方式。 |
| 测试 | B | `swift test` + smoke suite 已覆盖 9 个 tools 的回归，并新增了针对“前台焦点是否被抢占”的手工对比样本沉淀。 | 增加更多普通 app 的录制回归，减少只依赖 fixture 和一次性手工检查。 |
| 可观测性 | C | 已有 `doctor`、`snapshot`、smoke 输出，以及一组仓库内留档的官方 `computer-use` / 本仓库实现对比样本。 | 补统一日志级别、失败上下文和 release artifact 里的诊断信息，把一次性样本收敛成可重复采集流程。 |
| 安全 | B | 已明确本地-only、权限边界和 fixture test bridge 的作用域，并将内置 denylist 收缩到密码管理器。 | 增加 session approval 和更清楚的敏感 app policy，避免策略长期硬编码在仓库里。 |
