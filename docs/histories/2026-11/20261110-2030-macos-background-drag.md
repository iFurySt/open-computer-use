## [2026-11-10 20:30] | Task: 修复原生 macOS drag 的后台窗口投递

### 🤖 Execution Context
* **Agent ID**: OpenAI coding assistant
* **Base Model**: 运行时未提供已验证的模型标识，不推测填写
* **Runtime**: pi coding agent，本地 macOS

### 📥 User Query
> 在已建立的 Draft PR 中实现原生 drag 后台拖拽修复；保持现有接口，不加入曲线或形状规划。

### 🛠 Changes Overview
**Scope:** macOS OpenComputerUseKit、真实输入测试、相关用户与工程文档。

- `BackgroundDragDispatcher` 在默认 PID 投递中加入窗口号、窗口内坐标和必要的 target-only synthetic-active / key window；复用现有 SkyLight 桥，事件只公开 postToPid 一次。
- 真实 AppKit 对照证明本画布仅有焦点、仅有窗口字段或缺失 key 均不足；最小有效组合不需要 click primer、双投递、HID source 或原型的额外点击。保持原事件源、10 步直线与 30 ms 节奏。
- 几何 / 窗口身份 / 会话检查；按下前准备全部 release，取消后按最后已发送位置松开，再释放合成状态；并发失效的清理不再检查动作许可。
- 保持公开 MCP / JS API 和 global 授权门；后台初始观察和动作回读禁止激活恢复。投递提示不宣称 UI 成功。前台状态使用同步系统 AX focused application，避免长驻 CLI 的 NSWorkspace 缓存误判；收尾不撤销已成为真实前台的目标状态。
- 增加无 GUI 单测、真实 AppKit/native MCP 回归脚本；更新架构、安全、可靠性、skill、设计计划及 feature release note。

### 🧠 Design Intent (Why)
普通 PID 事件投递并不建立 AppKit 的窗口路由与输入状态。在后台画布真实输入对照后，把必要处理整合到已有 drag，而不是新增工具、方法参数或将 Agent 的曲线逻辑下沉到 MCP。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/BackgroundDragSimulation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{InputSimulation,ComputerUseService,SkyLightSPI,ToolDefinitions}.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/{BackgroundDragTests,DragReleaseTests,OpenComputerUseKitTests}.swift`
- `scripts/tests/macos-background-drag-smoke.mjs`
- `scripts/tests/fixtures/MacOSDragFixture.swift`
- `docs/macos-background-drag.md` 与关联设计、计划、安全、架构、可靠性和发布记录。
- `skills/open-computer-use/SKILL.md`、`skills/open-computer-use/references/usage.md`

### 验证记录
- `swift build --product OpenComputerUse` 通过。
- 本 checkout 修复前 native MCP baseline：真实画布事件 0 / 无笔迹，前台与指针断言通过。
- 修复后主场景连续 3 轮 native MCP / 完全遮挡的真实 AppKit 画布通过：每轮 12 个事件、实际路径、前台 active/key/first responder/失焦计数、PID、指针、窗口层级与目标合成状态清理均符合断言。
- 最终 14 个新增单测通过，覆盖初始拒绝、激活后撤销、非有限参数及中途成为前台；完整 XCTest 包 476 个测试，8 个 opt-in 等跳过，0 失败。更新工具说明后也同步更新旧文案断言，最终完整包复跑通过。
- `make ci` 通过，包含 JS/Python 及 Windows/Linux Go 单测；不等于真实 Windows/Linux 桌面测试。
- 本机 CLT 默认缺 XCTest；完整 Xcode 的新版 Swift 对未修改的 LockedUse 测试报错。采用 CLT + 完整 Xcode 的 XCTest framework / usr/lib 搜索与链接路径构建，再通过其 xctest runner 实际执行。没有把“no matching test cases”记作通过；命令见 `docs/macos-background-drag.md`。
- 扩展实机脚本最终完整通过：绘制回调、越界、窗口移动 / 关闭守卫和长驻 MCP 中目标已在真实前台的兼容性。早期一轮被桌面输入打断，未作为通过；关闭动画仍有窗口记录的情况按几何失效拒绝，修正了过窄的文案断言；前台兼容性发现的真实状态误判改为 AX 读取后复测通过。PR 保持 Draft。

### 未验证范围
其他 Space / toolkit、Finder 拖放和标题栏移动不作本修复的兼容承诺。未修改已安装 OCU，未发布制品或 bump 版本。
