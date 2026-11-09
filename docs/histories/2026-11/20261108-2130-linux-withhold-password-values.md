## [2026-11-08 21:30] | Task: Linux 快照不读取密码字段的值

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS；Linux 验证在 Debian trixie 容器（Xvfb、AT-SPI 2.56、GTK 3.24.49、GTK 4.18.6、Qt 6.8.2）`

### 📥 User Query
> Linux `get_app_state` 把 GTK 4 密码框里的明文写进快照，修复并补测试。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseLinux`

**Key Actions:**
- **[值不读取]**: AT-SPI role 为 `password text` 的节点不再读取 Text：快照的 `value` 为空，tree 行没有 `Value:`。
- **[选区不读取]**: 焦点在密码字段上时，`selectedText` 不读取选中的文字；焦点摘要（role 和名称）照旧。
- **[回归覆盖]**: 新增两个不依赖桌面的 Python 测试，修复前均失败。

### 🧠 Design Intent (Why)
GTK 4 的 `GtkPasswordEntry` 对 AT-SPI `GetText` 返回明文（GTK 3 返回圆点，Qt 6 返回空字符串），原实现把它原样写进 `value` 和 tree 行，密码因此进入模型上下文和日志。按 role 判断即可覆盖三种 toolkit 的密码字段；写入后的校验仍在 runtime 内部读取比较，不把值返回给调用方。

已知限制：GTK 4 中 `visibility=false` 的普通 `GtkEntry` 报告的 role 是 `text`，AT-SPI 上看不出它是密码，仍会读取。

### 📁 Files Modified
- `apps/OpenComputerUseLinux/runtime.py`
- `apps/OpenComputerUseLinux/runtime_test.py`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### Maintainer follow-up (2026-11-09)

- 用户授权依次处理 #178、#164、#181。补充 Linux 密码节点的 numeric fallback 防护，避免 Text 被过滤后改从 Value 接口读取。
- 检查 Windows 同类路径并补 UIA IsPassword 防护：普通值、缓存值和选区都受保护，未知标记不读取；批量缓存不预取密码值。
- 加入可重复 GTK 3/4 假密码 fixture 与 WPF PasswordBox 回归；普通文本作为正对照。边界见 `docs/password-fields.md`。

### Independent validation

- Debian trixie / GTK 3 与 GTK 4：旧 main 的 GTK 4 明文泄露被独立复现；修复后完整 runtime 快照和 native CLI 响应均保留普通文字、隐藏密码，聚焦密码选区不输出。
- Python 44 项通过；Linux Go 测试在容器通过，原生 MCP 动作回读 smoke 通过。
- Windows Go 测试与 PowerShell 观察分支、密码守卫测试通过；真实 WPF 由 Windows observation CI 检查。
