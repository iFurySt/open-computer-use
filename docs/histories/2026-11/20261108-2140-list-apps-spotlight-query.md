## [2026-11-08 21:40] | Task: list_apps 的 Spotlight 查询提速

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> list_apps 每次调用约 0.3 s，大部分花在 Spotlight 查询和逐条读取属性上；在不改变结果的前提下降下来。

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`

**Key Actions:**
- **[查询]**：去掉 `kMDItemFSName == "*.app"` 通配，改为在查询里按最近使用日期过滤；文件名是否以 `.app` 结尾改在结果里检查。
- **[属性]**：bundle id、文件名、显示名、日期和使用次数随查询一起取回；`kMDItemPath` 查询取不回，在通过前面的检查后才从 item 读取。
- **[顺序]**：日期检查放到打开 bundle 之前，窗口外的 app 不再读 Info.plist。
- **[测试]**：`AppDiscoveryTests` 用旧的全量扫描、逐条读取作为对照，比较结果。

### 🧠 Design Intent (Why)
本机实测：通配查询 116–129 ms（293 条结果），去掉通配 4–5 ms；293 条逐条读属性 306–719 ms，而两周窗口内只有 42 条。截止日期仍在代码里精确检查，结果与原实现一致。

### ✅ Validation
- 进程内 `AppDiscovery.listCatalog()` 连续 7 次：修改前 817 / 316–351 ms，修改后 71 / 13.5–15 ms；两次输出逐行相同（18 个 app）。
- `open-computer-use list-apps`（关闭 app agent 代理）整进程耗时：修改前 396–790 ms，修改后 74–116 ms，输出相同。
- `swift test`：454 项，8 跳过，0 失败。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AppDiscoveryTests.swift`
