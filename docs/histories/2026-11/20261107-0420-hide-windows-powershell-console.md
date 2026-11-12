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
`powershell.exe` is a console program. When its parent has no console (for example an MCP server launched with `DETACHED_PROCESS` by a desktop host), Windows allocates a new visible console for each call and it becomes the foreground window for one to three seconds. That steals keyboard focus from the user's app on every tool call, which defeats the point of background computer use. `CREATE_NO_WINDOW` runs the console application without allocating a console window; stdout and stderr still reach the pipes used by `CombinedOutput`, so the JSON protocol is unchanged.

### Validation
- `go test ./...` and `go build` in `apps/OpenComputerUseWindows`; `GOOS=linux go build` still compiles.
- The built `mcp` server was started from a `DETACHED_PROCESS` parent and driven with ten `list_apps` / `get_app_state` calls against an existing window while a `SetWinEventHook` foreground monitor and a visible-window poller ran: zero foreground changes and no new visible console window.

### Files Modified
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/hide_window_windows.go`
- `apps/OpenComputerUseWindows/hide_window_other.go`
- `apps/OpenComputerUseWindows/hide_window_windows_test.go`
- `docs/releases/feature-release-notes.md`

### Maintainer review — 2026-11-12

- Merged current main and resolved the release-note conflict, preserving both sets of entries. The production change remains confined to the Windows PowerShell child launch.
- Added `TestPowerShellFromDetachedParent`: starts an isolated Go test process with `DETACHED_PROCESS`, verifies that parent has no console window, and calls the production `runPowerShell` path. A temporary probe script checks the real PowerShell `GetConsoleWindow()` result, repeats a Unicode JSON round trip, and checks nonzero-exit/stderr propagation. It then runs the original runtime's read-only `list_apps`.
- The existing Windows observation workflow runs this test through `go test ./...`, followed by its real WPF / MCP tests; no new workflow or elevated permissions are needed.
- Local macOS Go tests and Windows amd64 test / arm64 runtime cross-compilation passed. Windows execution and the foreground behavior are separate evidence: cross-compilation alone does not prove either. Windows CI results are recorded on PR #160.

Run on Windows:

```sh
cd apps/OpenComputerUseWindows
go test -v -run 'Test(HideConsoleWindowSetsNoWindowFlags|PowerShellFromDetachedParent)$' .
```

`CREATE_NO_WINDOW` does not set the child's console handle; it does not disable redirected standard I/O. See [Microsoft's process creation flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags). The integration test checks console allocation and pipe behavior, while the contributor's Windows 10 foreground monitor remains the separate focus-change observation.
