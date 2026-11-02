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

### Locked Use

Locked Use is now supported on macOS. `OCU` temporarily unlocks your Mac after it has been locked so the agent can continue working, with protective services such as a full-screen shield in place during use.

![Open Computer Use Locked Use screen](./docs/assets/ocu-locked-use.webp)

See the [Locked Use guide](docs/locked-use.en.md) for setup, installed components, and permissions

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
ocu install-codex-mcp
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

Besides the MCP JSON config above, you can also use the built-in commands:

```bash
# Install into Codex by writing to ~/.codex/config.toml
open-computer-use install-codex-mcp

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

# Call a single Computer Use tool and print the MCP-style JSON result
open-computer-use call list_apps
ocu call list_apps
open-computer-use call get_app_state --args '{"app":"TextEdit"}'

# Run a sequence in one process so element_index state can be reused
# Sequence runs sleep 1s between successful operations by default
open-computer-use call --calls '[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]'
open-computer-use call --calls-file examples/textedit-overlay-seq.json --sleep 0.5

# Check permissions; onboarding only opens when something is missing
open-computer-use doctor

# macOS: query permission JSON without opening onboarding
ocu doctor --json

# Show help
open-computer-use -h
ocu -h
```

## Global Configuration

`ocu` supports global configuration starting with version 1.0.0 to accommodate different workflows and use cases. The default configuration file is `~/.config/ocu/config.json`. You can edit the file directly or use the `ocu config` subcommands. See the [configuration guide](docs/configuration.md) for details.

## Star History

<a href="https://www.star-history.com/?repos=iFurySt%2Fopen-computer-use&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&theme=dark&legend=top-left" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&legend=top-left" />
    <img alt="Star History Chart for open-computer-use" src="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&legend=top-left" />
  </picture>
</a>

## License

[MIT](./LICENSE)
