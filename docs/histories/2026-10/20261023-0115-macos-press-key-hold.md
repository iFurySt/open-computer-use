## [2026-10-23 01:15] | Task: macOS press_key 支持 hold_ms

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI / macOS`

### 📥 User Query
> 为 #106（Linux X11 `press_key.hold_ms`）补 macOS 对应实现：按住按键 `hold_ms` 毫秒后释放；参数名、范围、校验和报错文本与 #106 一致，最小改动。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **[schema 与校验]**: `press_key` 新增可选整数 `hold_ms`（`minimum` 1、`maximum` 5000）。dispatcher 在 `press_key` 分支开头校验，非 1–5000 的整数（含小数、字符串、布尔、null）统一返回 `hold_ms must be an integer from 1 to 5000`，与 #106 相同；省略时调用与之前完全一致。
- **[auto]**: `InputSimulation.pressKey` 在 `postToPid` 的 key down 与 key up 之间等待 `hold_ms`；修饰键在 key down 之前按下、key up 之后释放，整个按住期间保持按下。
- **[sky_key]**: 按键事件路径把同一个按住放进 `SkyKeyboardDispatcher.deliver`，目标窗口的 synthetic key 状态覆盖整个按住时长，之后照常恢复。带 `cmd` 的单字符组合键在 sky_key 下是菜单 `AXPress`，没有时长，带 `hold_ms` 时在改动目标焦点前直接拒绝，并提示改用 `auto`。
- **[fixture]**: fixture app 走 `FixtureBridge`，无法按住，带 `hold_ms` 时明确拒绝。
- **[布尔参数]**: JSON `true` 会被 Swift 桥接成 Int 1，原 `positiveInt` 的布尔检查排在 Int 之后从未生效。把检查提到最前，`hold_ms: true` 与 Linux 一样被拒绝；同一 helper 上的 `max_text` 等参数也不再把 `true` 当成 1。
- **[测试]**: 校验非法值、边界值 1 / 5000 / 80.0 可通过、sky_key 拒绝按住 cmd 组合键，以及 schema 的类型与范围。

### 🧠 Design Intent (Why)
逐帧轮询按键状态的应用（游戏、模拟器）可能漏掉瞬时按键。macOS 的按键投递原本就是 key down / key up 两个独立事件，按住只需在两者之间等待，不引入新的投递路径。

参数名、范围、校验和报错文本与 #106 一致，跨平台调用方只需一套参数。#106 在 Swift dispatcher 的同一位置加入了“仅支持 Linux X11”的拒绝；本改动在该位置改为真正的校验，后合入的一方删掉对方那几行即可。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SkyKeyboardSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- Swift 383 项测试通过（7 项跳过），`make check-docs` 通过。
- 真机，用一个只记录按键事件及接收时间的临时 AppKit 窗口：不带 `hold_ms` 时 key down / key up 在同一毫秒；`hold_ms: 1000` 时 key up 晚 1006 ms；`shift+b` 配 `hold_ms: 300` 时 shift 先于 b 按下，b 按住 309 ms，之后才释放 shift；sky_key 下 `c` 配 `hold_ms: 500` 按住 497 ms，窗口位于终端之后，前台 app 不变。`hold_ms: 0` 与 sky_key 的 `cmd+s` 配 `hold_ms` 均被拒绝，没有任何按键送达。
- TextEdit 新文档中 `a` 按住 1000 ms 只得到一个 `a`：`postToPid` 事件不经过系统的按键重复，不会产生 auto-repeat（X11 上长按可能重复，见 #106）。测试后关闭文档、不保存。
