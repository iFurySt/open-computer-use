## [2026-10-23 02:10] | Task: macOS 新增 press_menu

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS`

### 📥 User Query
> 把 fork 中按路径按下菜单栏命令的 `pressMenu` 移植到上游：通过 AXPress 按下，不用键盘或指针，app 留在后台也能用。复用上游 `sky_key` cmd 组合键已有的 AX 菜单遍历，不另写一套；确定路径格式，说明禁用项和找不到的菜单项如何报告，找不到时列出可选项。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`、`scripts/node-repl`、`apps/OpenComputerUseSmokeSuite`、文档

**Key Actions:**
- **[工具面]**: 按 `query` / `select_text` 的方式新增 `press_menu`（`app`、`path`），加入 `ToolDefinitions`、dispatcher、MCP instructions 的工具列表和 smoke suite 的工具清单；native surface 从 11 个变为 12 个。
- **[路径]**: `path` 是 `"File > Save As…"` 形式的字符串，按 `>` 切分并去掉首尾空格，至少两段且不能有空段，否则在访问 app 之前报参数错误。每段忽略大小写和首尾空格，`...` 等同 `…`。
- **[复用菜单遍历]**: `SkyKeyboardDispatcher.firstMenuItem` 从“只匹配快捷键”改为接收谓词和层数，cmd 组合键查找仍是同样的 6 层、同样的匹配条件；`press_menu` 用同一个函数逐级查找，每级只看上一级菜单的直接子项（菜单栏标题或子菜单的项在其 AXMenu 下两层）。列出可选项也用同一个函数。
- **[报告]**: 找不到时报错并列出该级所有菜单项；路径停在菜单标题或子菜单上时报错并列出其子项（按下会把菜单弹到屏幕上）；目标项为禁用状态时报错且不按下。
- **[会话与安全]**: 访问 app 前和按下前都检查会话与 Locked Use 租约；只解析已运行的 app，经过密码管理器 denylist；不激活、不 raise、不发送键盘或指针事件。按下后按 read-only recovery 回读窗口，窗口不可读（隐藏 app、没有窗口）时返回 `ok`，不把已执行的命令报告为失败。
- **[JS]**: 新增 `app.pressMenu(path)`，非字符串或空路径在调用 native 前拒绝。
- **[Linux / Windows]**: 不实现，与 `query` / `select_text` 相同，调用时返回既有的 `unsupportedTool("press_menu")`。

### 🧠 Design Intent (Why)
菜单栏是 macOS app 最稳定的命令入口，很多命令没有快捷键或快捷键因 app 而异。通过 AX 直接按下菜单项，不需要打开菜单、移动指针或让 app 到前台，与 `sky_key` 对 cmd 组合键的处理方式一致，因此复用同一个菜单遍历，避免两套逻辑分别演化。

路径用字符串而不是数组，因为它就是用户描述菜单命令的方式，也直接出现在错误信息里；代价是标题本身含 `>` 的菜单项无法指定。

实测 AppKit 对禁用菜单项的 `AXPress` 返回成功但什么都不做，若照常按下会把无效操作报告成成功。因此与 cmd 组合键查找跳过禁用项一致，以菜单项的 enabled 状态为准，禁用时直接报错。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyKeyboardSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/LockedUseDispatchTests.swift`
- `apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite/main.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `scripts/node-repl/open-computer-use-repl.test.mjs`
- `skills/open-computer-use/SKILL.md`
- `skills/open-computer-use/references/usage.md`
- `docs/references/js-repl.md`
- `docs/ARCHITECTURE.md`
- `docs/QUALITY_SCORE.md`
- `docs/SECURITY.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 单元测试：路径切分（含无空格写法）与 6 种不完整路径的报错；标题匹配的大小写、首尾空格、`...` / `…`；dispatcher 对单段路径直接报参数错误；撤销租约时 `press_menu` 在解析 app 之前抛出；工具数量 / 名称 / schema 与 MCP instructions；Node REPL 32 项测试通过（Persistent / Worker 两种 session）。
- 真机，TextEdit 以隐藏方式在后台启动，经进程内 CLI 调用，前台 app 全程不变：`file > new`（小写）新建一个窗口，开启回读时返回该隐藏窗口的 AX 与截图；`File > Nope` 列出 File 菜单的 17 项；`Nope > New` 列出菜单栏标题；`Format > Font` 报告会打开子菜单并列出其 16 项。
- 第一轮未检查禁用状态时，`Edit > Undo`（无可撤销）与隐藏 app 中的 `File > Close`（无 key window）都返回 `ok` 却没有效果，据此加入禁用项检查；第二轮两者均报告禁用且未按下。测试新建的窗口均已通过窗口关闭按钮关掉，未保存任何内容。
