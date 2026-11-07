## [2026-11-07 04:20] | Task: Hide the PowerShell console window of the Windows runtime

### Execution Context
* **Agent ID**: `primary`
* **Base Model**: `Claude Sonnet 5.5`
* **Runtime**: `Claude Code + Go 1.20`

### User Query
> Every Windows tool call briefly flashes a console window and takes the foreground when the MCP server was started without a console.

### Changes Overview
**Scope:** `apps/OpenComputerUseWindows`, `docs`

**Key Actions:**
- **[Hidden console]**: `runPowerShell` now starts `powershell.exe` through `hideConsoleWindow`, which sets `HideWindow` and `CREATE_NO_WINDOW` on the child. The non-Windows build gets a no-op.
- **[Regression test]**: `hide_window_windows_test.go` asserts the process attributes the helper sets.

### Design Intent (Why)
`powershell.exe` is a console program. When its parent has no console (for example an MCP server launched with `DETACHED_PROCESS` by a desktop host), Windows allocates a new visible console for each call and it becomes the foreground window for one to three seconds. That steals keyboard focus from the user's app on every tool call, which defeats the point of background computer use. `CREATE_NO_WINDOW` gives the child a console with no window; stdout and stderr still reach the pipes used by `CombinedOutput`, so the JSON protocol is unchanged.

### Validation
- `go test ./...` and `go build` in `apps/OpenComputerUseWindows`; `GOOS=linux go build` still compiles.
- The built `mcp` server was started from a `DETACHED_PROCESS` parent and driven with ten `list_apps` / `get_app_state` calls against an existing window while a `SetWinEventHook` foreground monitor and a visible-window poller ran: zero foreground changes and no new visible console window.

### Files Modified
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/hide_window_windows.go`
- `apps/OpenComputerUseWindows/hide_window_other.go`
- `apps/OpenComputerUseWindows/hide_window_windows_test.go`
- `docs/releases/feature-release-notes.md`
