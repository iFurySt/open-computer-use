# macOS 软件光标：新会话不再从屏幕左下角飞入

用户反馈软件光标“总是从左下角跳出来、到处乱窜”，不够平滑一致。

原因：光标没有当前位置时，第一段移动从 `defaultVisualCursorInitialTipPosition()` 出发，即屏幕原点（AppKit 全局坐标的左下角）。会话结束时的 `reset()` 和 30 秒空闲后的隐藏都会清掉位置，所以每个新会话、以及每次停顿超过 30 秒后的第一个动作，光标都从左下角横穿整个屏幕。一次性 CLI 调用（每次 `ocu call` 是一个会话）时每一步都会这样。

改动：新增 `lastSeenTipPosition`，在 `reset()` 和空闲隐藏清空位置前记下光标最后的位置，跨隐藏与会话保留；新的起点由 `visualCursorFreshStartTipPosition(lastSeen:pointer:fallback:)` 决定：优先最后位置，其次用户真实指针（`NSEvent.mouseLocation`），都没有时才用原来的屏幕原点。光标显示、动画与目标窗口跟随逻辑不变。同步 skill 的 Software Cursor 说明。

验证：新增 `CursorFreshStartTests`；`swift test` 全部通过，`make check-docs` 通过。真机（单屏、Roblox Studio）：结束会话后开新会话点击，`OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE` 记录的第一帧位于上一次点击的位置，而不是屏幕原点；点击正常落下。

由 Claude Code（claude-opus-5-5）实现，用户验证。
