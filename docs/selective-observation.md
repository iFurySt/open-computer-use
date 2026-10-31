# 按需观察

macOS、Windows、Linux 的 `get_app_state` 都可以选择读取 AX 或截图。原生参数 `include_ax` / `include_screenshot` 对应 JS 的 `includeAX` / `includeScreenshot`，原生和 combined getter 默认 `true`，不能同时设为 `false`。JS `getAXState()` 默认读取完整 AX 文本（`textLimit: "max"`），并设置 `includeScreenshot: false`；显式参数仍可覆盖。

| 需要什么 | JS 调用 | 实际采集 |
| --- | --- | --- |
| 只读控件和选区 | `await app.getAXState()` | AX、焦点、选区；不截图、不编码 |
| 只看画面 | `await app.getScreenshot({includeAX: false})` | 截图；不遍历 AX、不查焦点和选区 |
| 两者都要 | `await app.getAXStateAndScreenshot()` | 完整 AX 和截图 |

```js
var app = await cua.getApp("gedit", {initialState: false});
await app.getAXState();
```

只取截图后，旧元素索引及查询别名会失效，包括应用重启前的索引。坐标操作仍可使用本次观察的窗口位置；元素操作要先重新读取 AX。窗口标题相同不代表旧索引仍然有效。

原生 `get_app_state`、截图 getter 和 combined getter 不传参数时保持原行为。AX getter 默认不采集图片；只取 AX 后可继续操作元素，但截图坐标点击 / 拖拽要先重新获取截图；只取截图后则要重新读取 AX 才能使用元素索引。macOS 的 query 索引也会随纯截图观察失效。

## CLI 和 MCP

JS 的 `ocu js` / `ocu repl` 和 MCP `js` 使用上面的调用。直接调用原生 CLI / MCP 时使用 snake_case：

```sh
ocu call get_app_state --args '{"app":"TextEdit","include_screenshot":false}'
ocu snapshot --include-screenshot false TextEdit
ocu snapshot --include-ax false TextEdit
```

原生 MCP `get_app_state` 接收同样的 `include_ax` / `include_screenshot` 布尔值。`snapshot` 两个参数都接受 `true` / `false`，不能同时关闭。`snapshot` 一直只打印文本；需要图片内容时使用 JS 或 `call` / MCP。

这两个选项只控制本次显式观察，不改变动作回读。

## 和重复截图的关系

macOS / Linux 下的 JS 动作已默认关闭自动回读；`getAXState()` 默认不采集或编码图片；需要时显式传 `includeScreenshot: true`，或使用 `getAXStateAndScreenshot()`。AX getter 只移除已知的独立截图省略提示，保留完整控件文本和其他警告。直接使用 native MCP 时，它也会省去返回的 image block。

这里不做截图比较：请求了截图，即使画面相同也照常返回。“画面未变则省略图片”需要单独实现，通常仍要先截图再比较，主要减少传输和模型输入。后续可按会话、应用和窗口保存精确图像指纹，首次观察及状态重置时返回图片，并提供强制返回方式；不能仅凭 AX 没变化就认定画面没变化。

## 测试

```sh
swift test
python3 apps/OpenComputerUseLinux/runtime_test.py
(cd apps/OpenComputerUseLinux && go test ./...)
(cd apps/OpenComputerUseWindows && go test ./...)
node --test scripts/node-repl/*.test.mjs
```

真实 GTK 测试复用 [私有 D-Bus / Xvfb 环境](linux-action-read-back.md)，另外需要 Node.js：

```sh
(cd apps/OpenComputerUseLinux && go build -o /tmp/ocu-observation-test .)
bash scripts/run-linux-read-back-smoke.sh /tmp/ocu-observation-test --observation-checks
```

脚本包装真实生产采集函数，确认关闭的通道没有被调用；再通过 native MCP 和 Worker JS 检查 PNG、选区、旧索引拒绝、坐标操作及 AX 恢复。GTK 独立导出状态确认动作结果。这是 X11 / GTK / AT-SPI 测试，不代表 Wayland 或完整任务性能测试。

macOS 使用正常签名且已授权的 OCU 可执行文件验证真实 AppKit 窗口，无需修改准入配置：

```sh
node scripts/tests/macos-observation-smoke.mjs "/path/to/Open Computer Use.app/Contents/MacOS/OpenComputerUse"
```

它通过真实 AX / native MCP / CLI / Worker JS 验证三个采集模式、PNG、快照和 query 索引失效、坐标拒绝和元素恢复，并用现有 timing 日志确认跳过的采集分支未执行。窗口禁止成为 key/main window；脚本不向个人应用输入。

Windows 的 PowerShell 采集分支可用以下命令单独验证：

```powershell
pwsh -NoProfile -File scripts/tests/windows-observation.test.ps1 -RuntimePath apps/OpenComputerUseWindows/runtime.ps1
```

这个测试解析生产脚本并执行其中的观察函数，使用带计数的 UIA / 截图依赖验证分支。它不等于 Windows 桌面实测。

Windows 桌面测试需要已登录的交互会话、Windows PowerShell 和 Node.js：

```powershell
go -C apps/OpenComputerUseWindows build -o "$env:TEMP/ocu-observation.exe" .
pwsh -File scripts/tests/windows-observation-smoke.ps1 -NativePath "$env:TEMP/ocu-observation.exe"
```

脚本创建自己的 WPF 窗口，通过真实 UIA / native MCP / CLI / Worker JS 检查通道选择、旧索引拒绝、AX 恢复、Unicode 设值和截图坐标拒绝；再用同进程的 Win32 小窗口验证物理 1×1 边界，并检查 WPF 最小化、cloaked 时不返回图片，恢复后重新返回 PNG。`.github/workflows/windows-observation.yml` 在 Windows runner 执行这组检查。WPF 的通过结果不代表所有 WinForms / WinUI / Electron 控件都支持相同 UIA pattern。
