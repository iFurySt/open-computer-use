# 密码字段

密码字段仍显示名称、角色和位置，观察结果不返回字段值或选中文字。macOS 使用 `AXSecureTextField`，快照与 query 先读取角色信息，再决定是否读取值，选区同样过滤。Linux 使用 AT-SPI 的 `password text` 标记；Windows 使用 UIA 的 `IsPassword`，无法读取该标记时也不读取值或选区。Windows 的批量快照不预取 `ValuePattern.Value`，普通控件在确认非密码后读取。

这依赖应用正确标记密码控件，不按名称猜测。GTK 4 中关闭 visibility 的普通 GtkEntry 可能仍报告 `text`；这种未标记控件不能保证识别。截图由应用绘制，本规则不遮盖应用主动显示的明文。

Linux `set_value` 的内部验证暂时保留：不把读取值放进响应；密码控件若只提供圆点或空值，会报无法验证，调用方应重新观察，不直接重试。macOS 密码框的 `type_text` 使用键盘投递以保留已有内容和光标；`set_value` 只确认 AX 接受写入，不读取密码验证，不能把成功返回当成密码内容已验证。`select_text` 不支持按密码内容定位。

## 回归

使用固定假密码，不读取用户应用：

```sh
python3 apps/OpenComputerUseLinux/runtime_test.py
# Linux，已安装 GTK 3/4、AT-SPI、Xvfb 与 D-Bus
GTK_A11Y=atspi NO_AT_BRIDGE=0 xvfb-run -a dbus-run-session -- \
  python3 scripts/tests/linux-password-smoke.py
```

`--runtime <baseline-runtime.py> --expect-leak` 用于 GTK 4 修复前对照。测试检查完整快照中普通字段仍可读，密码值不进入结果。既有 Linux native MCP 动作 smoke 另行运行。

Windows 的 observation 测试检查禁止的读取与缓存请求；真实 WPF fixture 添加 PasswordBox，并通过 native MCP 检查普通、聚焦并选中密码时的响应。现有 Windows observation workflow 会运行这些检查。

macOS 可运行 `node scripts/tests/macos-text-input-smoke.mjs <signed-ocu-executable>`，再用 `OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE=1` 重跑。测试覆盖真实 NSSecureTextField 的追加和覆盖输入，以及故意暴露密码值的 provider：snapshot、选区、query 均不得请求该值。安装了 Locked Use 时，测试包须使用已批准的签名身份，不改变现有授权来强行通过。
