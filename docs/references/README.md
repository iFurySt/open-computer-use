# 外部参考资料

这个目录用于沉淀那些值得长期放进仓库、供 Agent 直接读取的外部参考材料。

适合放这里的内容包括：

- 团队会反复依赖的框架、部署或接入说明。
- 设计系统参考、API 使用约定。
- 对外标准、合作方协议或外部文档的简要整理版。
- 闭源依赖、第三方二进制或外部工具的逆向分析与整理结论。

不要把大段供应商文档原样塞进来。这里应该是经过筛选和整理后的资料。

## 当前目录

- `macos-locked-use-auth-transaction-timing-review.md`
  - 认证时序、build 1001365 空字符串 / 合成点击证据、诊断采集边界和隔离测试要求。

- `macos-locked-use-solution-review.md`
  - 用户提供锁屏自动化参考的逐项核对、固定 AXValue 探测边界和真实验证顺序。

- `macos-locked-use-authentication.md`
  - macOS Locked Use 的认证事务 ID / audit session 区别、保留现有 fallback 与离线安装规划边界。

- `codex-computer-use-reverse-engineering/`
  - 官方 `Codex Computer Use.app` / `SkyComputerUseClient` 的持续逆向分析资料；大体积一次性分析产物默认在本地 `research/` 下重新生成，不提交进仓库。
- `codex-network-capture.md`
  - 用 `mitmdump` + `scripts/codex_dump.py` 抓 Codex 上游 HTTP / WebSocket 流量，并把对应 `session_id` 的本地 `function_call` / `function_call_output` 摘要一起沉淀到 `artifacts/codex-dumps/` 做持续分析。
- `codex-local-runtime-logs.md`
  - 当抓包目录里的 `websocket/` + `local-sessions/` 仍不足以解释本地 tool / MCP 行为时，再补查 Codex 本地 `logs_2.sqlite`。
- `codex-computer-use-cli.md`
  - 仓库内 `scripts/computer-use-cli/` 的用途、使用方法，以及为什么探测官方 bundled `computer-use` 时要优先走 `codex app-server` 代理而不是 direct stdio。
- `background-input-benchmarks.md`
  - 后台点击 / 键盘 / snapshot / agent display 的实测数字：环境、方法、每张表的 n 与分位数、决定默认间隔的扫描、多 app 扫描结果和复现命令（英文）。
- `macos-window-visibility-and-spaces.md`
  - 被遮挡 / 其他 Space 窗口的 AX tree 与截图为什么会丢、WindowServer occlusion 通知 keep-alive、Chromium 懒加载 AX tree、已验证与未解决的边界。
- `macos-skylight-background-keyboard.md`
  - `key_method=sky_key` 的实机研究记录：为什么后台 Chromium 收得到按键却不输入文字、yabai key-window record、菜单快捷键走 AX、跨 Space 验证，以及哪些方案被实测否定。
- `agent-display-cost.md`
  - agent display 的 CPU / 内存 / 能耗实测：停靠窗口按显示器刷新率绘制、24 Hz 下限、hiDPI 与尺寸、创建/销毁的全局开销、restore 后 keep-alive 让窗口继续全速绘制，以及各设置下的截图与输入延迟（英文）。
