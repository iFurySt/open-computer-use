# open-computer-use

[![English](https://img.shields.io/badge/English-Click-yellow)](./README.md)
[![简体中文](https://img.shields.io/badge/简体中文-点击查看-orange)](./README.zh-CN.md)
[![Release](https://img.shields.io/github/v/release/iFurySt/open-computer-use)](https://github.com/iFurySt/open-computer-use/releases)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/iFurySt/open-computer-use)
<a href="https://llmapis.com?source=https%3A%2F%2Fgithub.com%2FiFurySt%2Fopen-computer-use" target="_blank"><img src="https://llmapis.com/api/badge/iFurySt/open-computer-use" alt="LLMAPIS" width="20" /></a>

> [!TIP]
> 对 Browser Use 感兴趣的话，可以看看 [open-browser-use](https://github.com/iFurySt/open-codex-browser-use)。

---

`open-computer-use` 是一个开源的 `Computer Use` 服务，已经包装成 `MCP` 协议，支持所有的 AI Agent 或 MCP Client 快速调用，实现 macOS、Linux 和 Windows 上的 `Computer Use` 能力。

项目的背后是 OpenAI 刚发布的 [Codex Computer Use](https://openai.com/index/codex-for-almost-everything/)，让我看到了基于 Accessibility 可以实现非抢占式 CUA 能力，因此决定复刻一个开源版本

在这期间我利用了之前写的 [harness 模版](https://github.com/iFurySt/harness-template) 开启了这个新项目。这是一个可以快速拉起面向 AI 仓库的 template，非常适合 100% AI-Generated 的项目，也是这一个月来我们最大的实践和收获。现在我们可以基于这套方法论快速实现很多东西；如果你有兴趣，我也写了一篇[文章](https://www.ifuryst.com/blog/2026/speedrunning-the-ai-era/)专门介绍这套方法论

## 演示

### Codex App 和 Codex CLI

[![open-computer-use 自定义演示封面](./docs/generated/readme-assets/open-computer-use-demo-cover.png)](https://youtu.be/2s6aVpGiwaQ)

<sub><em>`open-computer-use` 作为 Computer Use，在 Codex App 和 Codex CLI 里使用，和官方体验一致。</em></sub>

### Gemini CLI

https://github.com/user-attachments/assets/eacb3b15-f939-46c7-b3b3-6f876977a58d

<sub><em>Gemini CLI 通过MCP接入使用 `open-computer-use`，实现完整的 Computer Use 操作。</em></sub>

### Linux

https://github.com/user-attachments/assets/e036b1c8-2200-4896-abd4-19225915cf66

<sub><em>`open-computer-use` 在 Linux 里使用</em></sub>

### Locked Use
目前支持Locked Use，`OCU`会在锁屏之后临时解锁使用电脑（仅支持macOS），期间会有一系列的安全配套服务比如遮罩层来保证安全性
![Open Computer Use Locked Use screen](./docs/assets/ocu-locked-use.webp)
Locked Use 的开启方式、安装组件和权限见[文档](docs/locked-use.zh-CN.md)

## Quick Start

```bash
npm i -g open-computer-use
```

通过 npm 安装后也会同时提供短命令 `ocu`。

> [!IMPORTANT]
> macOS 运行环境要求 macOS 14.0 或更高版本。

**macOS 第一次使用前，需要授权 `Accessibility` 和 `Screen Recording` 的权限，windows和linux无需执行**

```bash
open-computer-use
# 或
ocu
```

开始用前可以通过一键安装到主流的Agent里：
```bash
# 一键安装到 Codex，写到 ~/.codex/config.toml 中
open-computer-use install-codex-mcp
ocu install-codex-mcp
```

也可以手动配置到你自己的客户端里：

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

一键安装skill：

```bash
# 安装到 Codex
npx skills add iFurySt/open-computer-use -g -a codex --skill open-computer-use -y
npx skills ls -g -a codex | rg 'open-computer-use'
```

安装到 Claude Code
```
npx skills add iFurySt/open-computer-use -g -a claude-code --skill open-computer-use -y
```

更新已有的全局安装，包括上面安装到 Codex 的那份：

```bash
npx skills update open-computer-use -g -y
```

也可以手动下载 [`open-computer-use` skill](./skills/open-computer-use) 安装

## 更多

除了直接用上面的 MCP JSON 配置，你也可以用一些内置子命令：

```bash
# 一键安装到 Codex，写到 ~/.codex/config.toml 中
open-computer-use install-codex-mcp

# 一键安装到 Codex 插件，主要方便在 Codex App 中使用
open-computer-use install-codex-plugin

# 一键安装到 Claude Code，写到 ~/.claude.json 中
open-computer-use install-claude-mcp

# 一键安装到 Gemini CLI 当前项目，写到 ./.gemini/settings.json
open-computer-use install-gemini-mcp

# 一键安装到 Gemini CLI 用户级配置
open-computer-use install-gemini-mcp --scope user

# 一键安装到 opencode，写到 ~/.config/opencode/opencode.json（或当前生效的配置文件）
open-computer-use install-opencode-mcp

# 直接调用单个 Computer Use tool，输出 MCP 风格的 JSON result
open-computer-use call list_apps
ocu call list_apps
open-computer-use call get_app_state --args '{"app":"TextEdit"}'

# 在同一个进程里编排连续动作，复用 get_app_state 拿到的 element_index
# 连续动作默认会在成功的相邻操作之间 sleep 1 秒
open-computer-use call --calls '[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]'
open-computer-use call --calls-file examples/textedit-overlay-seq.json --sleep 0.5

# 检查权限；只有缺失时才会拉起引导，已全部授权则只打印状态并退出
open-computer-use doctor

# macOS：只查询权限 JSON，不弹引导界面
ocu doctor --json

# 查看帮助
open-computer-use -h
ocu -h
```

## 全局配置

ocu 1.0.0后支持全局配置，以适应不同的使用方式和业务场景，默认配置存在 `~/.config/ocu/config.json`，期间可以直接到文件里编辑配置，也可以通过`ocu config`子命令去配置，更具体的可以看： [配置说明](docs/configuration.zh-CN.md)

## Star History

<a href="https://www.star-history.com/?repos=iFurySt%2Fopen-computer-use&type=date&legend=top-left">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&theme=dark&legend=top-left" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&legend=top-left" />
    <img alt="open-computer-use Star History 趋势图" src="https://api.star-history.com/chart?repos=ifuryst/open-computer-use&type=date&legend=top-left" />
  </picture>
</a>

## License

[MIT](./LICENSE)
