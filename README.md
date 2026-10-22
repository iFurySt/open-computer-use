# open-computer-use

[![English](https://img.shields.io/badge/English-Click-yellow)](./README.md)
[![简体中文](https://img.shields.io/badge/简体中文-点击查看-orange)](./README.zh-CN.md)
[![Release](https://img.shields.io/github/v/release/iFurySt/open-computer-use)](https://github.com/iFurySt/open-computer-use/releases)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/iFurySt/open-computer-use)
<a href="https://llmapis.com?source=https%3A%2F%2Fgithub.com%2FiFurySt%2Fopen-computer-use" target="_blank"><img src="https://llmapis.com/api/badge/iFurySt/open-computer-use" alt="LLMAPIS" width="20" /></a>

> [!TIP]
> Interested in Browser Use? Check out [open-browser-use](https://github.com/iFurySt/open-codex-browser-use).

---

`open-computer-use` is an open-source `Computer Use` service wrapped as `MCP`. Any AI agent or MCP client can use it to run Computer Use on macOS, Linux, and Windows.

This project was inspired by OpenAI's [Codex Computer Use](https://openai.com/index/codex-for-almost-everything/). It showed that non-intrusive CUA can be built on top of Accessibility, so I decided to build an open-source version.

I started this repo with my [harness template](https://github.com/iFurySt/harness-template), a template for quickly spinning up AI-first projects. It has been one of our most useful workflows lately, especially for nearly 100% AI-generated projects. I also wrote [a post](https://www.ifuryst.com/blog/2026/speedrunning-the-ai-era/) about the methodology behind it.

## Demos

### Codex App and Codex CLI

[![Open Computer Use custom demo cover](./docs/generated/readme-assets/open-computer-use-demo-cover.png)](https://youtu.be/2s6aVpGiwaQ)

<sub><em>`open-computer-use` used as Computer Use in Codex App and Codex CLI, matching the official experience.</em></sub>

### Gemini CLI

https://github.com/user-attachments/assets/eacb3b15-f939-46c7-b3b3-6f876977a58d

<sub><em>Gemini CLI connects to `open-computer-use` through MCP and runs full Computer Use actions.</em></sub>

### Linux

https://github.com/user-attachments/assets/e036b1c8-2200-4896-abd4-19225915cf66

<sub><em>`open-computer-use` running on Linux.</em></sub>

## Quick Start

```bash
npm i -g open-computer-use
```

The npm package also exposes `ocu` as the short CLI alias.

> [!IMPORTANT]
> The macOS runtime requires macOS 14.0 or later.

**On macOS, run it once and grant `Accessibility` and `Screen Recording`. Windows and Linux do not need this step.**

```bash
open-computer-use
# or
ocu
```

Before using it, install it into your agent:

```bash
# Install into Codex by writing to ~/.codex/config.toml
open-computer-use install-codex-mcp
```

Or add it to your own client manually:

```json
{
  "mcpServers": {
    "open-computer-use": {
      "command": "open-computer-use",
      "args": ["mcp"]
    }
  }
}
```

### Skill

Install the skill directly:

```bash
# Install for Codex
npx skills add iFurySt/open-computer-use -g -a codex --skill open-computer-use -y
npx skills ls -g -a codex | rg 'open-computer-use'
```

Install for Claude Code:

```bash
npx skills add iFurySt/open-computer-use -g -a claude-code --skill open-computer-use -y
```

Update an existing global install, including the Codex install created above:

```bash
npx skills update open-computer-use -g -y
```

You can also manually download and install the
[`open-computer-use` skill](./skills/open-computer-use).

## More

See the [Locked Use guide](docs/locked-use.en.md) for setup, installed components, and permissions.

Besides the MCP JSON config above, you can also use the built-in commands:

```bash
# Install into Codex by writing to ~/.codex/config.toml
open-computer-use install-codex-mcp
ocu install-codex-mcp

# Install as a Codex plugin, mainly for Codex App
open-computer-use install-codex-plugin

# Install into Claude Code by writing to ~/.claude.json
open-computer-use install-claude-mcp

# Install into Gemini CLI for the current project by writing to ./.gemini/settings.json
open-computer-use install-gemini-mcp

# Install into Gemini CLI user config instead
open-computer-use install-gemini-mcp --scope user

# Install into opencode by writing to ~/.config/opencode/opencode.json (or the active config file)
open-computer-use install-opencode-mcp

# Install through DeepSeek Harness's generic MCP compatibility path:
# verifies the server, then writes a profile patch, turn-boundary hook, and skill
open-computer-use install-dsh-mcp
./scripts/install-dsh-mcp.sh --profile web --no-hook

# Call a single Computer Use tool and print the MCP-style JSON result
open-computer-use call list_apps
ocu call list_apps
open-computer-use call get_app_state --args '{"app":"TextEdit"}'

# Inspect code-first runtime availability
ocu capabilities
ocu capabilities --json

# Run one JavaScript evaluation, from an argument, stdin, or a file
ocu js 'var apps = await cua.listApps({ emit: false }); nodeRepl.write(apps)'
printf '%s' 'nodeRepl.write(6 * 7)' | ocu js -
ocu js --file ./automation.mjs

# Keep JavaScript and cua bindings for the current terminal session
ocu repl

# Run a sequence in one process so element_index state can be reused
# Sequence runs sleep 1s between successful operations by default
open-computer-use call --calls '[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]'
open-computer-use call --calls-file examples/textedit-overlay-seq.json --sleep 0.5

# Check permissions; onboarding only opens when something is missing
open-computer-use doctor

# macOS: query permission JSON without opening onboarding
ocu doctor --json

# Run local validation from a source checkout
make smoke
OPEN_COMPUTER_USE_STRESS_LOOPS=20 make stress
make agent-smoke
make agent-smoke SCENARIO=fixture-full
node ./scripts/run-agent-smoke-tests.mjs --agents=claude,codex --command=open-computer-use
node ./scripts/run-agent-smoke-tests.mjs --scenario=fixture --agents=claude,codex --command=open-computer-use
node ./scripts/run-agent-smoke-tests.mjs --scenario=fixture-full --agents=claude,codex --command=open-computer-use
OPEN_COMPUTER_USE_HERMES_PROVIDER=anthropic OPEN_COMPUTER_USE_HERMES_MODEL=claude-opus-4-20250514 make agent-smoke AGENTS=hermes SCENARIO=fixture-full
node ./scripts/run-agent-smoke-tests.mjs --agents=hermes --hermes-provider=anthropic --hermes-model=claude-opus-4-20250514
node ./scripts/run-agent-smoke-tests.mjs --scenario=fixture --agents=hermes --hermes-provider=anthropic --hermes-model=claude-opus-4-20250514
node ./scripts/run-agent-smoke-tests.mjs --scenario=fixture-full --agents=hermes --hermes-provider=anthropic --hermes-model=claude-opus-4-20250514 --hermes-max-turns=12

# Show help
open-computer-use -h
ocu -h
```

`ocu js` closes its JavaScript Worker and native MCP child after one
evaluation. `ocu repl` keeps them for the current terminal session until
`.exit`, Ctrl-D, or termination; `.reset` clears its bindings. On macOS, the
separate hidden `Open Computer Use.app` permission agent may remain resident so
later commands reuse the same permission identity. `ocu mcp` continues to expose
the nine core native tools, plus `query` and `list_windows` on macOS.

The npm launcher itself currently requires Node.js 18 or newer. Its help always lists
`js` / `repl`, while `ocu capabilities --json` reports whether Node, the REPL
adapter/kernel, and the native runtime are available. Once started, it reuses
the current Node executable instead of looking up another `node` on PATH.

`ocu doctor --json` (macOS only) returns `platform`, `accessibilityTrusted`, `screenCaptureGranted`, `allGranted`, and `missingPermissions`. Missing permissions still exit with code 0; hosts should check `allGranted` and query again after authorization. The snapshot uses existing system API/TCC diagnostics and does not prove an operation succeeded; some permission changes may still require a process restart.

### Targeted query (macOS)

Find controls by text or role without taking a screenshot. See [query usage](docs/targeted-query.md).

## Cursor Motion

Cursor Motion is an open-source cursor motion system for macOS, based on public information shared by members of the Software.Inc team. You can download the app from the [Releases page](https://github.com/iFurySt/open-computer-use/releases).

[![Cursor Motion custom demo cover](./docs/generated/readme-assets/cursor-motion-demo-cover.png)](https://youtu.be/KRUq5GUHv1Q)

## Star History

<a href="https://www.star-history.com/?repos=iFurySt%2Fopen-computer-use&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&theme=dark&legend=top-left" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&legend=top-left" />
    <img alt="Star History Chart for open-computer-use" src="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&legend=top-left" />
  </picture>
</a>

## License

[MIT](./LICENSE).

### Persistent configuration

Use `ocu config` to inspect settings and `ocu config set image.format jpg` to persist a macOS screenshot preference. Environment overrides remain supported. See [configuration](docs/configuration.md) ([简体中文](docs/configuration.zh-CN.md)) for settings and CLI commands.
