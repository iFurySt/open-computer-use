## [2026-11-14 18:10] | Task: 为 Linux Wayland 增加 ydotool 输入路径

### 🤖 Execution Context
* **Agent ID**: `deepseek-flash`
* **Base Model**: `DeepSeek V4.1 Flash 1017`
* **Runtime**: `OpenCode`

### 📥 User Query
> 在 Wayland 下 `global` 点击和 `move_mouse` 无法驱动隐藏面板与原生终端；希望 Open Computer Use 在 Wayland 下也能移动指针、点击和输入，并为此向上游提交 PR。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseLinux`、`skills/open-computer-use`、README

**Key Actions:**
- **Wayland 输入后端**: Linux runtime 检测 `XDG_SESSION_TYPE` / `WAYLAND_DISPLAY`，在 `click_method: "wayland"` 时用 `ydotool mousemove --absolute` 加 `ydotool click`；新增 `move_mouse` 工具按桌面绝对坐标移动指针；`type_text` 新增 `key_method: "wayland"`，通过 `ydotool type --file -` 输入。
- **安全与依赖**: 与 `global` 共用 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` 门槛；`OPEN_COMPUTER_USE_YDOTOOL` 可指定二进制或设为 `0` 禁用；缺失 ydotool 时返回明确错误。
- **文档与测试**: 中英文 README、usage 参考补充 Wayland 安装说明；Go 工具定义与门槛测试、runtime 的 ydotool 命令构造与缺失依赖测试。

### 🧠 Design Intent (Why)
Wayland 合成器不会接受 AT-SPI 的指针与按键合成，原有 `global` 路径在 KWin 等原生 Wayland 会话里没有效果。`ydotool` 走内核 `uinput`，不依赖 X11，能在 Wayland 下移动真实指针并输入。新增路径保持显式选择，X11 与默认 `auto` 行为不变；依赖外部二进制时明确报错，不静默失败。

### 📁 Files Modified
- `apps/OpenComputerUseLinux/main.go`
- `apps/OpenComputerUseLinux/main_test.go`
- `apps/OpenComputerUseLinux/runtime.py`
- `apps/OpenComputerUseLinux/runtime_test.py`
- `README.md`
- `README.zh-CN.md`
- `skills/open-computer-use/references/usage.md`
