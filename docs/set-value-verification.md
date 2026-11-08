# 写入验证

`app.setValue(index, value)`、CLI 和 MCP 的 `set_value` 在 macOS、Windows、Linux 上都会读取写入后的实际值。控件忽略了写入，或把内容改成了别的值，会返回错误。

```js
await app.setValue(index, " 0015 "); // 空格和前导零都要保留
await app.setValue(index, "");       // 清空
```

| 控件返回的类型 | 比较方式 |
| --- | --- |
| 文本（包括 Windows UIA ValuePattern、Linux EditableText） | 原始字符精确比较，不裁空白、不忽略大小写、不做 Unicode 归一化 |
| 原生数值（macOS AX、Linux AT-SPI Value） | 按数值比较，例如 15 和 15.0；不会把文本框里的 0015 当成 15 |
| 原生布尔（macOS AX） | true/1、false/0 对应布尔值 |

值尚未匹配时，最多轮询 0.6 秒，只重读、不重复写入。关闭完整动作回读（`OPEN_COMPUTER_USE_ACTION_READ_BACK=0`）仍然校验，macOS 也会在读取和返回前检查会话。单次系统 API 的阻塞时间不属于轮询预算。

Linux 在写入前拒绝只读字段，什么都不写：AT-SPI 状态含 `READ_ONLY`，或文本字段（role `text` / `entry` / `password text`）缺少 `EDITABLE`。Qt 6 的只读 `QLineEdit` 同时报告 `READ_ONLY` 和 `EDITABLE`，并且照样接受 `SetTextContents`，写入后回读一致，单靠验证发现不了；GTK 3 关闭 editable 的输入框只是不带 `EDITABLE`。Qt 6 的 spin box 不带 `EDITABLE`，所以 spin button 只看 `READ_ONLY`。

验证失败不代表控件完全没变化。先重新观察，再决定是否重试；OCU 不会自动改用键盘或其他输入路径。验证只确认读取时的值，不保证应用之后不会再次修改它。

## Windows 状态类动作

Windows 上 `perform_secondary_action` 的 Toggle、Select、Expand、Collapse，以及 `click` 落到 SelectionItem / Toggle pattern 时（复选框、单选按钮、列表项），同样回读控件状态：Toggle 要求状态改变，Select 要求已选中，Expand / Collapse 要求展开 / 折叠，最多轮询 0.6 秒，不重复发送。读不到预期状态时返回错误并提示先重新观察，因为动作可能稍后才生效，盲目重试会把 Toggle 切回去。ScrollPattern 翻页时，如果已经翻过至少一页后 pattern 才拒绝，就停在那里，不再交给滚轮回退把全部页数再滚一遍。

## 回归测试

- macOS：`node scripts/tests/macos-set-value-smoke.mjs <signed-native-executable>`，真实 AppKit 文本控件，覆盖正常、忽略、改写、延迟、清空、空白和 Unicode，同时检查关闭/开启完整回读和 JS 错误传播。
- Linux：在私有 Xvfb / D-Bus 中运行 `python3 scripts/tests/linux-set-value-smoke.py --native <native-executable>`，真实 GTK / AT-SPI，覆盖正常、忽略、长度限制、延迟生效和只读；不代表所有 Wayland/toolkit。
- Windows：`scripts/tests/windows-set-value-smoke.ps1 -NativePath <native-executable>`，真实 WPF 自定义 ValuePattern；已接入 Windows observation CI。状态类动作的决策逻辑见 `scripts/tests/windows-pattern-readback.test.ps1`（pattern 替身，任意 pwsh 可运行）。

测试使用自有窗口和数据，不修改个人应用。

macOS 已标记的密码框例外：只确认 AX 写入被接受，不读取秘密验证；成功不表示内容已验证。普通控件仍使用上述回读验证。密码观察和平台差异见 [密码字段](password-fields.md)。

Qt 6 只读回归：在已安装 PyQt6 的私有 Xvfb/D-Bus 会话运行 `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 python3 scripts/tests/linux-qt-readonly-smoke.py --native /path/to/binary`。修复前 binary 可加 `--expect-baseline-write` 验证错误写入；脚本只操作自己创建的控件，同时检查普通文本框和 spin box。
