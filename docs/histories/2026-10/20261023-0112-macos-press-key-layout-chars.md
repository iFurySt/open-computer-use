## [2026-10-23 01:12] | Task: macOS press_key 支持键盘布局中的符号字符

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS`

### 📥 User Query
> 把 fork 里已经在用的 press_key 布局字符映射整理成上游 PR：`?`、`@`、`{` 这类不在具名键表里的单个字符不再报 `unsupported key`。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **[布局字符]**: `KeyPressParser` 在具名键表之外，用 `UCKeyTranslate` 读取当前键盘布局：能用一个主键盘按键打出的字符（直接或按住 shift）映射到该按键，需要 shift 时自动加上，已显式写了 shift 时不重复添加。具名键优先，`a`–`z`、`0`–`9` 等原有映射不变。
- **[按需读取]**: 只在 token 不是具名键时读取布局（一次约 0.02 ms），会话中途切换键盘布局也能跟上，不缓存过期的表。
- **[小键盘]**: 构表时跳过小键盘按键，`*` 映射到主键盘的 shift+8；小键盘仍用 `kp_*` 名称。
- **[sky_key 菜单匹配]**: `ParsedKeyPress` 新增 `shiftedCharacter`。sky_key 把 cmd 组合键换成菜单快捷键时不计字符隐含的 shift：菜单把 `cmd+?` 记为字符 `?` 加 cmd（Finder 帮助菜单项的 `AXMenuItemCmdChar` 为 `?`，`AXMenuItemCmdModifiers` 为 0）。
- **[测试]**: 用显式加载的 US 布局校验字符表，与机器当前布局无关；再按当前布局校验解析结果：自动加 shift、不重复 shift、sky_key 菜单快捷键为 `?` 加 cmd。

### 🧠 Design Intent (Why)
`press_key` 只认具名键表，Agent 想按 `?`（例如打开帮助搜索的 `cmd+?`）或 `@`、`{` 时只能报错，或者自己推算美式键位写成 `shift+/`，换个布局就按错。按字符查当前布局，Agent 写的就是想得到的字符，按键位置由布局决定。

具名键优先，是为了不改变任何现有调用的行为。投递路径不需要改：auto（`postToPid`）和 sky_key 的按键事件本来就按 `modifiers` 依次按下、释放修饰键，自动加的 shift 与手写的 shift 走同一条路径；macOS 侧没有全局键盘投递路径。只有 sky_key 的菜单匹配需要知道 shift 是字符自带的。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/KeyMapping.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyKeyboardSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- Swift 384 项测试通过（7 项跳过），`make check-docs` 通过。
- 真机（ABC 布局，与 US 相同）：用一个只记录按键事件的临时 AppKit 窗口接收，auto 下 `?`、`@`、`{`、`*` 分别到达 key code 44 / 19 / 33 / 28，均带 shift，shift 在按键之后释放；TextEdit 新文档中依次得到 `?@{*`，测试后关闭文档、不保存。
- sky_key：该窗口位于终端之后，`?`、`{` 带 shift 送达，前台 app 不变；窗口没有对应菜单项时，`cmd+?` 回落为 cmd+shift+/ 按键事件。菜单匹配依据 Finder 帮助菜单项的 AX 属性（只读取，未按下菜单）。
