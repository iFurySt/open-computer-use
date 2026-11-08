## [2026-11-08 23:00] | Task: Windows 状态类 pattern 动作回读验证

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI，macOS 主机；PowerShell 7.5 在 Linux 容器里跑决策逻辑测试，没有 Windows 桌面`

### 📥 User Query
> 延续 #111 的 set_value 回读：Windows 的 Toggle、Select、Expand / Collapse 和滚动也要确认结果，控件忽略时不能报成功。

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseWindows`、`scripts/tests`、`.github/workflows/windows-observation.yml`、文档

**Key Actions:**
- **[Wait-PatternState]**：与 `Invoke-VerifiedSetValue` 相同的 0.6 s、50 ms 轮询，只重读不重发；读取异常算作尚未达到。
- **[Invoke-VerifiedToggle / Select / Disclosure]**：Toggle 要求状态与之前不同；Select 要求 `IsSelected`；Expand 要求不再是 Collapsed，Collapse 要求是 Collapsed。失败信息说明动作可能稍后生效，先读取状态再决定是否重试。`perform_secondary_action` 与 `click` 的 `Invoke-PreferredClick`（SelectionItem / Toggle 分支）都走这里；Invoke 没有可读的状态，保持原样。
- **[Invoke-Scroll]**：ScrollPattern 已经翻过至少一页后才抛错时返回已处理，不再交给滚轮回退再滚全部页数；第一页就被拒绝时仍回退。
- **[windows-pattern-readback.test.ps1]**：pattern 替身覆盖生效、被忽略（只发一次）、已在目标状态，以及滚动的部分翻页 / 直接拒绝 / 完整翻页。

### 🧠 Design Intent (Why)
这些 pattern 方法不返回结果；控件可能拒绝改变（应用否决、绑定的状态不放）。原来一律报成功，模型以为复选框已勾上、节点已展开。Toggle 的回读必须提示先观察，否则延迟生效的 Toggle 被重试会切回原状态。ScrollIntoView 不验证：`IsOffscreen` 在最小化或被遮挡的窗口里对所有元素都可能为真，回读会误报。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `scripts/tests/windows-pattern-readback.test.ps1`
- `.github/workflows/windows-observation.yml`
- `docs/set-value-verification.md`
- `docs/ARCHITECTURE.md`
- `docs/releases/feature-release-notes.md`

### ✅ Validation
- 同一组替身下，origin/main 对被忽略的 Toggle（secondary action 与点击复选框）、Select（点击列表项）、Expand 都报成功；3 页滚动在第 1 页后被 pattern 拒绝时返回 false，交给滚轮再滚 3 页。本分支四种都报“could not be verified”，滚动返回 true。新测试在 origin/main 上失败，本分支通过。
- 现有决策测试在 pwsh 7.5 下通过；`go vet`、`go test -race`、`GOOS=windows go vet`、windows amd64 / arm64 构建通过。
- 哪些真实控件会忽略这些 pattern、状态更新是否都在 0.6 s 内可读，只能在 Windows 桌面上确认；现有 smoke 点击的都是 Invoke 按钮，不受影响。
