# 定向查找（macOS）

知道控件的文案或角色时，可以直接查找，不用先截图或读取整棵 AX 树。应用需要已经运行，查询不会启动、激活或抬升窗口。

在持久 MCP 会话或 `ocu repl` 中：

```js
var safari = await cua.getApp("Safari", { initialState: false });
var result = await safari.query({ text: "Compose", role: "button", exact: true });
nodeRepl.write(result);
```

确认结果后，可以在同一会话里操作索引：

```js
if (!result.truncated && result.matches.length === 1) {
  await safari.click(result.matches[0].index);
}
```

`getApp()` 默认仍会读取初始状态。加上 `initialState: false` 才会跳过。

CLI 也可以单独查看查询结果：

```sh
ocu call query --args '{"app":"Safari","text":"Compose","role":"button","exact":true}'
```

不同 CLI 调用不能共享索引。索引只在当前 native 会话有效，120 秒后过期，最多保留 5000 个；重置或结束会话后需要重新查询。操作前会重新检查应用进程、窗口、控件和当前位置，验证失败时不会使用旧坐标。

## 参数与结果

`text` 和 `role` 至少填一个。同时填写时，两者都要匹配。文字不区分大小写，匹配 title、description、value、tooltip（`AXHelp`）或 identifier。自身没有文字的控件按它包含的文字匹配，与屏幕上看到的一致：网页把一个结果逐字母画成单字符文本（`R`、`S`、`I`、空白、`S`…）时，可用 `RSI Strategy` 找到它，结果的 title 就是这段文字；只返回最小的那个控件，不返回它的外层容器。角色可以写 `button` 或 `AXButton`。

| JS 参数 | native 参数 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `text` | `text` | 无 | 查找文案，最多 1000 个 UTF-16 编码单元 |
| `role` | `role` | 无 | AX 角色，最多 1000 个 UTF-16 编码单元 |
| `exact` | `exact` | `false` | 完整文字匹配；不开则按子串匹配，精确匹配失败不会自动放宽 |
| `limit` | `limit` | `20` | 最多返回多少项，正整数，上限 100 |
| `maxNodes` | `max_nodes` | `500` | 最多遍历多少个节点，正整数，上限 5000 |
| `windowId` | `window_id` | 当前窗口 | 指定应用的窗口 ID，范围 1–4294967295 |

返回对象包含 `matches`、`truncated`、`stop_reason`、`visited_nodes`、`window_id` 和生效的 `limit` / `max_nodes`。每项包含 `index` 及可读取的角色、文案、值、标识、窗口内坐标、动作。

`truncated: true` 表示查询不完整，即使 `matches` 是空数组，也不能认定控件不存在。`stop_reason` 为 `limit`、`max_nodes`、`timeout`、`ax_error` 或 `text_limit`；完整搜索为 `complete`。长文字只搜索开头的有界片段，输出文案最多 1000 字符。达到结果上限时，也会保守标记不完整。

遍历采用 2 秒协作式截止时间，并限制每次 AX 调用的等待时间；正在执行的系统调用不能被这个截止时间强行中断。查询依赖应用暴露的 AX 控件，不保证找到未渲染的列表行或窗口外的控件。Windows / Linux 暂不支持。
