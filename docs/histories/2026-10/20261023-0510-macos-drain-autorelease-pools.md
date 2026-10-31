## [2026-10-23 05:10] | Task: 每次请求释放 autorelease pool，空闲客户端不再轮询，光标层级刷新降到 10 Hz

### Execution Context

- Agent ID: `Claude Code`
- Base Model: Claude Opus 5.5
- Runtime: Claude Code CLI / macOS arm64

### User Query

> 让 harness 本身在空闲和长会话里尽量省 CPU 和内存：测出常驻成本，找出泄漏和空闲唤醒，修掉能修的，并给出前后数字。

### Changes Overview

- 请求跑在 autorelease pool 永不释放的线程上：`StdioMCPServer.run` 的读循环、每个 `AppAgentConnection` 线程（直到客户端断开）、proxy 的主线程读循环。每张截图的 `NSBitmapImageRep`、缩放后的 `CGImage`、编码后的图片和响应字节都活到会话结束。现在三个读循环各自每个请求一个 pool，`ComputerUseToolDispatcher.callTool` 外层也包一个，单次调用内产生的对象在返回后释放。
- `AppAgentConnection` 的断开检测原来每 100 ms 无条件 `recv(MSG_PEEK)` 一次，每个空闲客户端每秒唤醒 agent 10 次。现在只在处理请求期间轮询；请求之间阻塞读本身会在对端挂断时返回，随后 `defer` 照常结束 Locked Use。
- 软件光标空闲摆动的 60 Hz timer 每帧调用 `refreshActiveOrderingIfNeeded()`：两次 `CGWindowListCopyWindowInfo` 和一次强制 `order(.above, relativeTo:)`，都是 WindowServer 往返，约占 timer 时间的 80%。改为每 6 帧（10 Hz）一次，被抬起的目标窗口最多 0.1 s 后光标回到其上方。摆动帧率和幅度不变。
- `writeObservationSnapshot` 每帧复制整个 `ProcessInfo.environment` 只为发现变量未设置，先用 `getenv` 判断。

### Design Intent

不改任何工具输出和截图像素，只改对象寿命和唤醒频率。pool 放在读循环和 `callTool` 两层：读循环覆盖响应编码，`callTool` 覆盖从其他入口（stream / 嵌套调用）进入的工具调用。断开检测只在请求期间需要（长请求中客户端断开要尽快结束 Locked Use），请求之间由阻塞读负责。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/MacOSAppAgentProxy.swift`

### Validation

- origin/main 与本分支各构建 release，进程内 `mcp`（`OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1`）对三个从不激活的探针 app 循环 300 次 `get_app_state`（带 / 不带截图）和 `query`，每 25 次读一次 `ri_phys_footprint`：
  - origin/main：27.5 MB → 第 50 次 123 MB → 第 300 次 577 MB，第 50 次后每次增长约 1.8 MB。
  - 本分支：11.3 MB → 13.2 MB → 12.6 MB，不再增长。
- 直接启动 `__open-computer-use-app-agent`，连接空闲客户端各测 10 s：1 个客户端 10.0 → 0.1 次唤醒/s，2 个 20.8 → 0.1 次唤醒/s。
- 同一探针，`click` 后光标空闲摆动 30 s 期间（每段约 10 s，2 轮中位数）：harness CPU 13.4–16.5% → 9.4–11.2%。WindowServer CPU 36–39% → 29–34%，但光标隐藏后的基线两次也相差约 4 个百分点，只作参考。光标隐藏后两者相同（约 0.02%）。
- `swift test`（跳过 `CursorWindowFollowTests`）：374 项，7 项跳过，0 失败。

### 2026-10-31 合并前复核

- 同步最新 main；让断连检测持续到响应写完，防止慢客户端阻塞写入时提前停止检测。
- 新增 `scripts/tests/macos-request-lifecycle-smoke.mjs` 和 `MacOSResourceProbe.swift`：真实 AppKit 截图、stdio MCP / 独立 app-agent 内存、空闲唤醒、反复连接关闭及响应中断连后继续服务。`--measure-only` 可用于旧版对照。
- 同一签名 release 制品与 main 对照，各路径连续 100 张截图：第 20～100 次 main footprint 增长约 32.1 MiB / 54.8 MiB，修复版 -1.25 MiB / 约 0 MiB；单个空闲客户端 10 次唤醒/秒降到 0。
- 10 次连接关闭后 descriptor 数恢复；响应发送中断开后仍可连接并请求。该验证在正常解锁桌面进行，没有声称覆盖受保护会话的租约释放。
- `swift test`：406 项、9 跳过、0 失败，包含窗口跟随/光标单元回归；`make check-docs`、`git diff --check` 通过。
