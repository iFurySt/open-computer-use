# Virtual displays require explicit host opt-in

Date: 2026-10-30

Request: add a configuration switch, default off, and omit the virtual-display
parameter while disabled.

- Added `virtualDisplay.enabled` and `OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED`.
- Gated native tool schemas, JS guidance, covered-window hints and creation paths;
  retained explicit restoration and turn/connection cleanup.
- Added configuration/dispatch/schema regressions and packaged the JS config
  dependency with standalone plugins. Windows/Linux omit the unsupported option.
- Updated configuration, architecture, security, usage and release documentation.

Creation is opt-in because adding a virtual monitor can affect a user's existing
display arrangement. These tests do not create displays on the developer's desktop.

Validation: 381 native tests passed (7 skipped), 48 REPL/config/CLI tests and
4 repository Node tests passed. Native MCP smoke verified schema gating and
rejection before app lookup. Windows Go suite and the affected Linux schema
tests passed. Full Linux testing requires Linux; repo-hygiene reports files
already absent from the base branch. `make check-docs` passed.
