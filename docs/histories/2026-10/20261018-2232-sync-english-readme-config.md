## [2026-10-18 22:32] | Task: 同步英文 README 配置说明

### 🤖 Execution Context
* **Agent ID**: `/root`
* **Base Model**: `GPT-6`
* **Runtime**: `Codex desktop`

### 📥 User Query
> 中文版 README 已修改，照着同步英文版。

### 🛠 Changes Overview
**Scope:** 首页 README 文档

**Key Actions:**
- 按中文版新增独立的 Global Configuration 章节，说明 1.0.0 起支持全局配置、默认文件位置和两种编辑方式，并链接英文配置文档。
- 移除 License 下的旧配置说明，同步 License 链接格式。
- 将用户修改的中文版与英文同步一并提交；`git diff --check` 和 `make check-docs` 验证通过。

### 🧠 Design Intent (Why)
让英文首页与用户本轮调整后的中文配置说明保持一致，并把配置入口放到独立章节。

### 📁 Files Modified
- `README.md`
- `README.zh-CN.md`
- `docs/histories/2026-10/20261018-2232-sync-english-readme-config.md`
