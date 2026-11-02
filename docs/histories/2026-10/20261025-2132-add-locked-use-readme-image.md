## [2026-10-25 21:32] | Task: Add Locked Use image and synchronize English README

### 🤖 Execution Context
* **Agent ID**: `/root`
* **Base Model**: `GPT-6`
* **Runtime**: `Codex desktop`

### 📥 User Query
> 将提供的 Locked Use WebP 图片移动到仓库合适的位置，并在英文 README 增加仅包含图片的 Locked Use 小节；中文文案由用户稍后编写，再据此补充英文。
> 排查 README 中已删除的 Persistent configuration 段落为何仍然存在，并恢复此前的配置文档整理。
> 以用户最新精简的中文 README 为准，同步英文内容与结构。

### 🛠 Changes Overview
**Scope:** README and documentation assets

**Key Actions:**
- 将用户提供的图片原样移入 `docs/assets/ocu-locked-use.webp`。
- 在英文 README 的 Demos 下增加 Locked Use 小节，并根据用户随后提供的中文补充 macOS 临时解锁与保护服务说明。
- 确认 `96d44ad` 的 README 配置整理只存在于 `codex/doctor-json-permissions` 分支，尚未进入 `main`；将其中的中英文全局配置段落迁移补回当前工作区，移除旧的持久化配置小节。
- 按最新中文同步英文的精简范围，删除 DeepSeek Harness、JS / REPL、运行时细节、开发测试命令和定向查询介绍，保留相同的安装与调用示例及全局配置入口；Cursor Motion 小节随用户的最新版本移除。
- 将 `ocu install-codex-mcp` 短命令示例对齐到 Quick Start。
- 收入用户后续手动调整：将中英文 Locked Use 文档入口从“更多”移至对应演示图片下方。
- 检查图片可解码、相对引用有效及 diff 格式。
- 验证中英文章节结构与命令示例一致，`make check-docs` 和 `git diff --check` 通过。

### 🧠 Design Intent (Why)
使用仓库内的静态图片展示 Locked Use 外观，以用户维护的最新中文内容为准同步英文，保持两份 README 的结构、命令示例和信息范围一致。

### 📁 Files Modified
- `README.md`
- `README.zh-CN.md`
- `docs/assets/ocu-locked-use.webp`
- `docs/histories/2026-10/20261025-2132-add-locked-use-readme-image.md`
