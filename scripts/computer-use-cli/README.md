# computer-use-cli

Small Go CLI for probing Codex desktop-control tooling.

This directory is intended to be run from `scripts/computer-use-cli/` inside the repo:

```bash
cd scripts/computer-use-cli
go run . list-tools --transport app-server
go run . call list_apps --transport direct --server-bin /path/to/open-computer-use
go run . call-seq --transport direct --server-bin /path/to/open-computer-use --calls-file /tmp/calls.json
```

It supports two transports:

- `direct`: talk to a stdio MCP server directly with the official Go MCP SDK transport layer.
- `app-server`: talk to `codex app-server`, create an ephemeral thread, then proxy `mcpServer/tool/call` through the signed Codex host.

`auto` is the default:

- for the official bundled proprietary `computer-use`, it uses `app-server`; this is currently reliable for inventory probes, not raw tool calls
- for explicitly provided non-Sky binaries such as `open-computer-use`, it uses `direct`

## Commands

```bash
go run . resolve-server
go run . list-tools --transport app-server
go run . call list_apps --transport direct --server-bin /path/to/open-computer-use
go run . call get_app_state --transport direct --server-bin /path/to/open-computer-use --args '{"app":"TextEdit"}'
go run . call-seq --transport direct --server-bin /path/to/open-computer-use --calls-file /tmp/calls.json
```

Explicit transport examples:

```bash
go run . list-tools --transport app-server
go run . list-tools --transport direct --server-bin /path/to/open-computer-use
go run . call list_apps --transport direct --server-bin /path/to/open-computer-use
go run . call-seq --transport direct --server-bin /path/to/open-computer-use --calls-file /tmp/calls.json
```

Flags can appear either before or after the tool name for `call`:

```bash
go run . call --server-bin /path/to/server list_apps
go run . call list_apps --server-bin /path/to/server
```

`call` creates a fresh ephemeral app-server thread per invocation. If you need `get_app_state`
followed by one or more action tools in the same official `computer-use` session, use
`call-seq` with a JSON array:

```json
[
  {"tool": "get_app_state", "args": {"app": "TextEdit"}},
  {"tool": "set_value", "args": {"app": "TextEdit", "element_index": "2", "value": "cursor probe 01\ncursor probe 02"}},
  {"tool": "scroll", "args": {"app": "TextEdit", "element_index": "1", "direction": "down", "pages": 1}}
]
```

This repo includes a ready-to-run example at
`../../examples/textedit-overlay-seq.json`.

Before running it, make sure `TextEdit` already has a normal document window
open; otherwise `get_app_state` may only expose the application root and the
hard-coded `element_index` values in the sample will no longer line up.

## Default target

By default, the CLI auto-discovers the official bundled `computer-use` plugin under:

```text
~/.codex/plugins/cache/openai-bundled/computer-use/<version>
```

For local compatibility testing, auto-discovery currently prefers a non-translocated
`1.0.750` root at `~/.codex/plugins/computer-use` when that root is present and
its plugin manifest reports `1.0.750`. If that root is not available, the CLI
falls back to the installed cache version under `~/.codex/plugins/cache/...`,
then to the newest installed version. Use an explicit version selector when you
need a different target:

```bash
COMPUTER_USE_PLUGIN_VERSION=1.0.755 go run . resolve-server
go run . resolve-server --plugin-version latest
go run . list-tools --transport app-server --plugin-version host
```

You can override that with:

```bash
COMPUTER_USE_PLUGIN_ROOT=/path/to/plugin-root
COMPUTER_USE_PLUGIN_VERSION=1.0.755
COMPUTER_USE_SERVER_BIN=/path/to/server-binary
```

or the equivalent flags:

```bash
--plugin-root /path/to/plugin-root
--plugin-version 1.0.755
--server-bin /path/to/server-binary
```

`--plugin-root` and `--server-bin` take precedence over `--plugin-version`.
The version selector affects CLI target resolution, direct launches, and the
temporary `mcp_servers."computer-use"` override passed to `codex app-server`.
Use `--plugin-version host` when you want app-server mode to leave the Codex
host config untouched. Codex CLI config overrides do not parse quoted dotted
keys, so the app-server override intentionally uses `mcp_servers.computer-use.*`.

For app-server mode, you can also override the Codex host binary:

```bash
CODEX_APP_SERVER_BIN=/Applications/Codex.app/Contents/Resources/codex
go run . list-tools --transport app-server
```

## Verified behavior in this workspace

- Direct mode successfully connects to the local `open-computer-use` stdio server and can both `list-tools` and `call list_apps`.
- Direct mode against the official bundled proprietary `computer-use` exits during initialization when launched outside Codex.
- That same failure reproduces with the official Go SDK example client `examples/client/listfeatures`, so the issue is not specific to this CLI.
- App-server mode can still list the official bundled `computer-use` tools through a signed Codex binary.
- As of official bundled `computer-use` `1.0.755`, raw `mcpServer/tool/call` from this external helper can return `Sender process is not authenticated` even though Apple Events/TCC accepts the request. The supported path for official tool calls is a normal Codex agent/tool invocation; this helper should not be treated as a general bypass for the proprietary service-side sender authorization.
- For local compatibility tests, this CLI now prefers bundled `computer-use` `1.0.750` from the non-quarantined `~/.codex/plugins/computer-use` root and passes the resolved target to `codex app-server` as a temporary MCP override. In this workspace, cache copies with `com.apple.quarantine` can be AppTranslocated and return `Apple event error -1708`; the non-translocated root can call `list_apps`.

Example working invocation against `open-computer-use`:

```bash
go run . list-tools \
  --transport direct \
  --server-bin ~/.codex/plugins/cache/open-computer-use-local/open-computer-use/1.1.4/scripts/launch-open-computer-use.sh
```

Example working comparison flow against a local repo build:

```bash
swift build --product OpenComputerUse
cd scripts/computer-use-cli
go run . call-seq \
  --transport direct \
  --plugin-root ../.. \
  --server-bin ../../.build/debug/OpenComputerUse \
  --calls-file ../../examples/textedit-overlay-seq.json
```

Example inventory probe against the official bundled `computer-use`:

```bash
go run . list-tools --transport app-server
```
