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

验证失败不代表控件完全没变化。先重新观察，再决定是否重试；OCU 不会自动改用键盘或其他输入路径。验证只确认读取时的值，不保证应用之后不会再次修改它。

## 回归测试

- macOS：`node scripts/tests/macos-set-value-smoke.mjs <signed-native-executable>`，真实 AppKit 文本控件，覆盖正常、忽略、改写、延迟、清空、空白和 Unicode，同时检查关闭/开启完整回读和 JS 错误传播。
- Linux：在私有 Xvfb / D-Bus 中运行 `python3 scripts/tests/linux-set-value-smoke.py --native <native-executable>`，真实 GTK / AT-SPI，覆盖正常、忽略、长度限制和延迟生效；不代表所有 Wayland/toolkit。
- Windows：`scripts/tests/windows-set-value-smoke.ps1 -NativePath <native-executable>`，真实 WPF 自定义 ValuePattern；已接入 Windows observation CI。

测试使用自有窗口和数据，不修改个人应用。
