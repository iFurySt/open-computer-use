## [2026-11-08 21:35] | Task: Linux set_value 写入前拒绝只读字段

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS；Linux 验证在 Debian trixie 容器（Xvfb、GTK 3、GTK 4、Qt 6）`

### 📥 User Query
> Linux `set_value` 会改写 Qt 的只读输入框并返回成功，修复并补测试。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseLinux`、`scripts/tests`

**Key Actions:**
- **[写入前拒绝]**: `set_element_value` 在任何写入之前检查 AT-SPI 状态：含 `READ_ONLY`，或文本字段（role `text` / `entry` / `password text`）缺少 `EDITABLE`，直接报错 `read-only; nothing was written`。
- **[spin button]**: Qt 6 的 spin box 不带 `EDITABLE`，spin button 只看 `READ_ONLY`，可写的 spin box 不受影响。
- **[回归覆盖]**: 新增 Python 测试（Qt 6 与 GTK 3 的只读状态组合、spin button）；`linux-set-value-smoke.py` 增加关闭 editable 的 GTK 输入框，并按用例检查错误文字。

### 🧠 Design Intent (Why)
#111 的回读验证能发现被忽略的写入，但发现不了“写进去了、却不该写”：Qt 6 的只读 `QLineEdit` 同时报告 `READ_ONLY` 和 `EDITABLE`，接受 `SetTextContents`，回读与请求一致，于是 `set_value` 改写了用户无法编辑的字段并返回成功。GTK 3 关闭 editable 的输入框不改内容，但要等满 0.6 秒，报告“写入可能已改变控件”。状态在写入前就能读到，拒绝放在写入之前，错误信息说明什么都没写。

### 📁 Files Modified
- `apps/OpenComputerUseLinux/runtime.py`
- `apps/OpenComputerUseLinux/runtime_test.py`
- `scripts/tests/linux-set-value-smoke.py`
- `docs/set-value-verification.md`
- `docs/releases/feature-release-notes.md`

### Maintainer validation

- 基于最新 main 保留密码保护与 #180 输入框点击修复，解决测试辅助类冲突。
- 新增真实 Qt 6 原生 MCP 回归脚本：旧版会将只读 QLineEdit 的 fixed 改为 changed；新版拒绝且内容保持 fixed。可写 QLineEdit 与不带 EDITABLE 的 QSpinBox 仍正常写入。
- 真实 GTK 3 set_value 两种回读模式通过，补只读字段最终值断言。Linux Go 全套、48 项 Python 测试、文档和 diff 检查通过。
- Qt 测试需等待 AT-SPI 注册，并用 fixture PID 定向，不依赖应用名称。所有窗口位于私有 D-Bus/Xvfb，不操作用户桌面。
