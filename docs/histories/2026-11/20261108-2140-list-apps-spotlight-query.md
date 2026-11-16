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

### 2026-11-16 维护者复核

- 保留去掉文件名通配符和提前过滤日期的优化；改用每个 MDItem 的一次 MDItemCopyAttributes 批量读取当前属性，然后筛日期，最后打开 Info.plist。
- 真实负对照发现查询属性缓存不可靠：同一个结果，MDQueryGetAttributeValueOfResultAtIndex 返回较旧日期和次数，MDItemCopyAttribute 返回较新值。最初怀疑多副本排序；逐项对照确认缓存陈旧才是这条失败的原因。因此不使用查询日期条件/属性缓存，避免提前遗漏或给出旧使用记录。
- 多副本仍按实际日期/次数选择最新有效记录；参考实现独立全扫描并逐属性读取，按相同语义去重，不依赖 Spotlight 未定义的遍历顺序。
- 当前 14 天与显式 90 天截止都与全扫描记录集合、日期和次数一致；无索引时显式 skip。最初原 PR 在扩大截止范围时仅返回 28 条而参考返回 53 条，这个失败已消除。
- 最终真实 CLI 六轮暖态中位 217.2 ms，基线 708.0 ms（约快 3.3 倍）。31 行的应用集合和顺序一致，唯一文本变化是测试期间浏览器真实使用次数增加 1，未把这次动态差异写成逐字相同。
- 最终 Swift 全套与仓库 CI 结果记录在批次计划。没有提交应用清单、原始本机元数据或签名信息。
