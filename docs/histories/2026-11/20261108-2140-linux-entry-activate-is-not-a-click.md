## [2026-11-08 21:40] | Task: Linux 点击 GTK 3 输入框不再触发 Enter

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS；Linux 验证在 Debian trixie 容器（Xvfb、GTK 3、GTK 4、Qt 6、Firefox ESR、Chromium）`

### 📥 User Query
> Linux `click` 按 element_index 点击 GTK 输入框时执行了它的 `activate`（等于按 Enter），表单被提交、焦点没进去；修复并补测试。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseLinux`、`scripts/tests`

**Key Actions:**
- **[点击 action 选择]**: `preferred_action_index` 跳过 GTK 3 文本字段（role `text` / `entry` / `password text` / `spin button`）的 `activate`。`auto` 因此落到已有的指针点击，`accessibility` 报告无法点击。
- **[其他 toolkit 不变]**: GTK 4、Gecko、Chromium 的 `activate` 和按钮等其他控件的 action 照旧。
- **[回归覆盖]**: 新增 Python 测试（GTK 3 文本字段走指针、其他 toolkit 保留 `activate`）；`linux-read-back-smoke.py` 按 element_index 点击输入框，检查焦点进入且 activate 计数不变。

### 🧠 Design Intent (Why)
GTK 3 给输入框的唯一 action 是 `activate`（“Activates the entry”），执行它会发出 `GtkEntry::activate`，即用户按 Enter：对话框会按默认按钮，搜索框会提交。原来的 action 列表把 `activate` 当作点击，`click` 因此提交了字段，焦点也没有进入。人点击输入框是把光标放进去，GTK 3 的屏幕坐标可用，指针点击就是对的做法。

GTK 4 用同名 action，实测（4.18）执行后没有可见效果；但 X11 上 GTK 4 报告的控件 extents 不可用（都在 0,0），改走指针会点到别处，所以保持不变。Gecko 和 Chromium 对网页输入框的 `activate` 是聚焦（页面的 focus 事件触发），保持不变。

### 📁 Files Modified
- `apps/OpenComputerUseLinux/runtime.py`
- `apps/OpenComputerUseLinux/runtime_test.py`
- `scripts/tests/linux-read-back-smoke.py`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### Maintainer validation

最新 main 整合后，Linux Go 全套与 46 项 Python 测试通过。私有 D-Bus/Xvfb 的真实 GTK 3 原生 MCP 测试通过：auto 点击获得焦点且 activate 计数为零，显式 accessibility 点击拒绝且不触发 activate；真实 Return 仍使计数增加。默认/禁用动作回读与焦点/选区 smoke 通过。旧 binary 在同一 accessibility 点击用例错误返回 ok，负对照失败。保留 GTK 4/Gecko/Chromium 的既有行为；本轮未安装浏览器复测。
