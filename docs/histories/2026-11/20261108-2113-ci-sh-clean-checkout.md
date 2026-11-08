## [2026-11-08 21:13] | Task: 让 scripts/ci.sh 在干净检出上通过，并在每个 PR 上运行

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> `scripts/ci.sh` 在干净的 main 检出上第二步就退出，从没跑到 `go test`；修到能过，并让它在 PR 上跑。

### 🛠 Changes Overview
**Scope:** 仓库 CI（`scripts/`、`.github/workflows/`、`docs/CICD.md`）

**Key Actions:**
- **仓库卫生检查只查真实文件**: `check-repo-hygiene.sh` 删掉 10 个仓库里早已不存在的模板文件（`.editorconfig`、PR / issue 模板、`docs-check.yml` 等），保留 `.github/workflows/ci.yml`；缺文件、README 含 CRLF、CONTRIBUTING 不提 `make check-docs` 仍然失败。
- **新增 `ci.yml`**: PR、main push 与手动触发时在 ubuntu-24.04 跑 `scripts/ci.sh`，Action 全部固定 SHA，`contents: read`。
- **配置测试不再依赖本机安装**: `ocu-config.test.mjs` 检查打包后的插件适配器能否 import 时，把路径放进 `process.argv[1]`，适配器因此当作入口启动 MCP 服务并 spawn `open-computer-use`；PATH 上没有安装版（CI 与干净机器）就 ENOENT 失败，有安装版则会真的拉起它。改为把文件 URL 写进 `-e` 代码，只验证 import。
- **Linux runtime 桥接测试只在 Linux 上跑**: 两个假 `python3` helper 走的 `runPython` 在非 Linux 上直接报错，macOS 上 `ci.sh` 因此在 Linux 模块的 `go test` 失败；helper 在非 Linux 上 `t.Skip`，ubuntu CI 照常全部运行。

### 🧠 Design Intent (Why)
`ci.sh` 是 `docs/CICD.md` 说的基础门禁，但它要求的文件有 10 个不在仓库里，`check-repo-hygiene.sh` 每次 exit 1，后面的测试从未在干净检出上跑过，也没有 workflow 运行它。只删掉不存在的条目，不恢复模板文件，也不扩大检查范围。

验证：干净的 origin/main 上 `ci.sh` exit 1（缺 11 个文件，其中包括本次新增的 `ci.yml`）；修复后在 Linux 容器（Node 24、Go 1.26.1、PATH 上没有 `open-computer-use`）中 `ci.sh` exit 0，Node 53 项、Python 全部通过，两个 Go 模块 `go test` 通过且 0 跳过；macOS 上（PATH 同样没有安装版）`ci.sh` 也 exit 0，Linux 模块跳过 12 个桥接子测试。配置测试在 PATH 去掉安装版后修复前失败（ENOENT）、修复后通过；删掉打包后的 `ocu-config.mjs` 时 import 检查仍然失败。卫生检查删掉 `CODEOWNERS` 或 README 加 CRLF 时仍 exit 1。

### 📁 Files Modified
- `scripts/check-repo-hygiene.sh`
- `scripts/node-repl/ocu-config.test.mjs`
- `.github/workflows/ci.yml`
- `docs/CICD.md`
