# macOS key_sequence：重叠按住的按键

用户在 Roblox Studio 里用 OCU 测游戏：角色要边走边跳。游戏每帧读取“按住”的键，`press_key` 的按下和抬起是同一刻发出的，角色不动；两次独立调用也无法在按住 W 的同时按空格。

改动：新增 macOS 工具 `key_sequence`。一次调用按顺序执行步骤，每步恰好一个动作：`down`（按住一个键或修饰键）、`up`（松开已按住的键）、`press`（点按一个键或组合键，沿用 press_key 写法）、`wait_ms`（0–5000 的整数毫秒，期间按住的键保持按下）。`key_method: sky_key` 时整条时间线在同一次 synthetic focus 内完成，结束后恢复一次。

安全：先整体校验（未知键、`up` 未按住的键、重复 `down`、步数 200 与总等待 10000 ms 上限），再一次性创建所有 CGEvent，任何事件创建失败都不发送；时间线结束时仍按住的键按相反顺序松开，按住的修饰键会带到期间的每个事件上。`wait_ms` 拒绝布尔值和小数（JSON `true` 经 NSNumber 会被 `as? Int` 读成 1，做法与 #116 对 `hold_ms` 的修正一致）。

与 #116（press_key `hold_ms`）和 #106（Linux 按住）互补：单键按住可用 `hold_ms`，需要多个键重叠时用 `key_sequence`。本 PR 不改 press_key。

验证：`KeySequenceTests` 覆盖解析、校验、事件顺序与修饰键标志、结束时自动松开、schema；工具数量测试更新为 12；`swift test` 全部通过，`make check-docs` 通过。真机（macOS 27.2、Roblox Studio Play 模式，位置由游戏内读取）：按住 W 并在 0.4 s、1.2 s 两次点按空格，角色两次起跳约 7.5 studs，空中保持 24 studs/s 前进，共走 48 studs；按住 W 后再按住 D 并起跳，方向转为 45° 对角，松开后无残留按键。

由 Claude Code（claude-opus-5-5）实现，用户验证。
