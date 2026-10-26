## [2026-10-23 01:28] | Task: 让没有名字的 AX 节点在 get_app_state 和 query 中可读

### Execution Context

- Agent ID: `Claude Code`
- Base Model: `Claude Opus 5.5`
- Runtime: Claude Code CLI

### User Query

> 自身没有 label 的节点应按它包含的文字命名，与人看到的一致。网页常把一个结果（例如搜索建议）画成一个无名容器，里面是逐个字母的静态文本（"R"、"e"、"l"…），以便加粗已输入的字母，这时没有任何节点带着画面上的名字。连续的单字符文本应拼成单词，其中的空白文本就是词间空格。tooltip（AXHelp）和 identifier 也应能作为名字。已有名字的节点输出不变，不增加每个节点的 AX 往返。

### Changes Overview

- `get_app_state`：通用容器的文字摘要把连续的单字符文本拼回单词，空白静态文本在这段字母中作为词间空格。原本超过 8 段文字就不摘要，逐字母画的结果会变成一行一个字母，现在显示为一行，例如 `container RSI Strategy`。不含小写字母的连续单字符（日历表头 `S M T W T F S`、数字、中文单字）保持原样。
- `query`：文字额外匹配 AXHelp 和 identifier（树里显示为 `Help:` / `ID:`）；自身没有 title、description、value 的节点按它包含的文字匹配，只返回最小的匹配节点，结果 title 为这段文字；只有 tooltip 的控件以 tooltip 作 title。
- 动作前的重新校验同样接受 tooltip / identifier，对按包含文字找到的节点重新读取其子树文字，内容变化时仍要求重新查询，不会点到已经换了内容的旧节点。
- 同步 `query` 工具 schema 说明、中英文查询文档和功能发布记录。

### Design Intent

文字摘要本来就会读取每个后代的 role 和 value，空白文本只是在同一次读取中保留下来，拼词不增加 AX 调用。`query` 的包含文字由遍历已经批量读到的 title / value 自底向上拼出，AXHelp 也放进同一次 `AXUIElementCopyMultipleAttributeValues`，每个节点的往返次数不变；只有按包含文字命中的结果在动作前多读一次自己的子树。不含小写字母时不拼词，是为了不把日历表头、数字和中文单字连成一个假词；代价是全大写且逐字母绘制的名字在树里仍以空格分开，但 `query` 用树里显示的同一段文字可以找到它。

既包含字母又包含链接的可点击结果行，树里仍按原样逐行显示字母：上游为保留链接导航目标而不摘要这类容器，在逐个子节点渲染时识别字母需要对每个子节点多读 role / value，本次不做；`query` 仍能按包含文字找到它。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/TargetedAXTests.swift`
- `docs/targeted-query.md`
- `docs/targeted-query.zh-CN.md`
- `docs/releases/feature-release-notes.md`

### Validation

- `swift test`：新增拼词与包含文字命名的纯函数测试（含逐字母、带空白、日历表头、数字、中文、角色过滤和已命名节点）；既有快照渲染测试全部通过。
- `CursorWindowFollowTests.testServiceClickRegistersLiveWindowAndFeedbackMatchesMovedButton` 偶发失败，在未修改的基线上同样出现（72 次中 3 次），原因是动作前解析到另一个窗口的 bounds，与本次改动无关。
- 真机 Chrome（独立临时 profile）打开本地测试页：修改前逐字母绘制的两个结果各输出 20 多行单字母，修改后为 `container Relative Strength Index` 和 `container RSI Strategy`；日历表头和其他节点输出不变。修改前 `query` 找不到 `RSI Strategy`、`Rising Stars`、`Close panel`，修改后分别返回对应结果行和带 tooltip 的按钮；对查询结果执行 `click` 后页面显示 `picked 2`。
