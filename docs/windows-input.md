# Windows 输入

默认使用 UI Automation 和窗口消息。滚动回退保留窗口 bounds，并按滚轮消息要求传递屏幕坐标；DPI bridge 使用物理像素。需要真实鼠标 / 按键时，在启动 OCU 的进程环境中设置：

```powershell
$env:OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS="1"
```

| 调用 | 默认 | 开启环境开关后 |
| --- | --- | --- |
| `app.click(index)` / `auto` | UIA 优先，再窗口消息 | UIA 优先，再真实指针 |
| `app.click([x,y], {clickMethod:"global"})` | 拒绝 | 真实指针 |
| `clickMethod:"app_post"` / `"accessibility"` | 各自指定的投递路径 | 保持指定路径 |
| `app.drag(...)` | 窗口消息 | 真实指针 |
| `app.scroll(index, direction, pages)` | ScrollPattern 优先，再窗口消息 | ScrollPattern 优先，再真实指针 |
| `app.pressKey(key)` | 窗口消息（组合键拒绝） | 窗口消息（组合键拒绝） |
| `app.pressKey(key, {keyMethod:"global"})` | 拒绝 | 真实按键 |

原生 MCP / CLI 参数使用 `click_method`、`key_method`。`type_text` 不提供 global 方式；`sky_click` / `sky_key` 是 macOS 能力。

窗口消息形式的按键和字符发给目标窗口线程里有键盘焦点、且位于目标窗口内的控件（`GetGUIThreadInfo`）；线程没有报告这样的控件时发给窗口本身，与原来一致。应用从键盘状态读取 Ctrl / Shift / Alt，投递消息不会改变键盘状态，所以 `ctrl+a` 这类组合键用窗口消息只会变成单独的 `a`：auto 方式直接拒绝，需要组合键时用 `key_method=global`。`type_text` 先写入有焦点的 Edit / RichEdit 控件（只读时拒绝）；不知道焦点时，只有窗口里唯一的文本框才会被选中，有多个时拒绝，不再写入第一个。

真实输入会移动系统指针，可能将目标放到前台。发送前核对已观察的进程 / 窗口、当前几何、前台及坐标命中窗口。按索引进行的物理输入还核对 UIA runtime ID 和当前元素位置，拒绝已消失、替换或移动的元素。窗口移动、被其他窗口遮挡或无法切换前台时会报错，需要重新观察或让目标可见。不会模拟 Alt 强行抢前台，也不会在指定 app_post / accessibility 失败时切到真实输入。

按键 / 鼠标用 SendInput，并检查是否插入成功。真实鼠标支持左 / 中 / 右键及 1–3 次点击，拒绝无效按钮和过大的点击次数。组合键先完整校验，再按下；异常时释放本次按下的键 / 按钮。系统完整性级别限制仍适用；进程强制终止也不能保证执行 finally。

## 验证

```powershell
go -C apps/OpenComputerUseWindows test ./...
go -C apps/OpenComputerUseWindows build -o "$env:TEMP/ocu-input.exe" .
powershell.exe -NoProfile -File scripts/tests/windows-input.test.ps1 -RuntimePath apps/OpenComputerUseWindows/runtime.ps1
pwsh -File scripts/tests/windows-input-smoke.ps1 -NativePath "$env:TEMP/ocu-input.exe"
```

桌面测试需要已登录 Windows 会话、Windows PowerShell、pwsh 和 Node.js，只操作自有临时窗口。验证默认窗口消息滚动回退、四向滚轮、截图坐标点击、拖拽、组合键、输入释放、移动 / 遮挡拒绝、屏幕右侧捕获与 Worker JS。夹具自定义 WM_MOUSEWHEEL / WM_MOUSEHWHEEL 处理并更新真实 ScrollViewer 偏移，结果由独立状态文件确认；不代表所有 GUI toolkit 都响应窗口消息。

脚本记录实际窗口 DPI，并比较截图尺寸与独立物理窗口矩形。正常 DPI 的通过不能替代 125% / 150% / 多显示器实测。原有正常 / 1×1 / 最小化 / cloaked 截图检查也在同一 Windows PR 工作流运行。

实现依据：[滚轮消息屏幕坐标](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel)、[横向滚轮方向](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel)、[SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)、[SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)、[线程 DPI 上下文](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext)。
