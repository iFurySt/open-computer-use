## [2026-11-08 21:22] | Task: 用按 checksum 固定的 gitleaks 扫描凭据和隐私信息

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `Claude Opus 5.5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 仓库目前没有任何 secret 扫描；加一个固定版本、按 checksum 校验的 gitleaks，带上协作约定里禁止提交的隐私规则，先扫完整历史。

### 🛠 Changes Overview
**Scope:** 仓库 CI（`scripts/`、`.github/workflows/`、`docs/`）

**Key Actions:**
- **`scripts/check-secrets.sh`**: 下载 gitleaks 8.30.1（Linux / macOS 的 x64 与 arm64），sha256 与固定值不符就 exit 2，然后扫描 HEAD 可达的每个 commit。
- **`.gitleaks.toml`**: 保留 gitleaks 默认凭据规则，加上 home 目录路径、个人邮箱、机器名、Tailscale IP / MagicDNS 名五条隐私规则，占位用户、保留测试域名等整类无害匹配按规则 allowlist。
- **`.gitleaksignore`**: 现有历史里的 3 条无害发现按 fingerprint 放行，各写原因。
- **`secret-scan.yml`**: PR、main push 与手动触发时完整检出历史并运行脚本，`contents: read`，checkout 不保留凭据。
- **文档**: `docs/CICD.md` 说明扫描、放行方式与 squash 合并下的 fingerprint 注意事项；`docs/SUPPLY_CHAIN_SECURITY.md` 对应关系加一行。

### 🧠 Design Intent (Why)
协作约定和 history 规范都禁止把本地路径、密钥写进仓库，但没有检查守住它。扫描放在独立脚本里，本地和 CI 跑同一命令；不改 `scripts/ci.sh`，让它保持无网络依赖。

验证：完整历史（main 288 个 commit；连同全部 22 个上游分支共 412 个）只有 3 条发现，均为无害：Sparkle 公钥、已删除的 README home 路径、测试里的按键名 `ctrl+unmapped`；没有真实凭据。放行后 exit 0；去掉一条放行、或新 commit 里写入 home 路径、个人邮箱、Windows 默认机器名、Tailscale IP、`.ts.net` 名、GitHub token 时均 exit 1；占位路径、noreply / example 邮箱、git remote、`@2x` 资源名、网段基址不报；行内 `gitleaks:allow` 生效；改动固定 sha256 时 exit 2。四个平台的固定 sha256 均与官方 checksums 文件及实际下载一致。

### 📁 Files Modified
- `scripts/check-secrets.sh`
- `.gitleaks.toml`
- `.gitleaksignore`
- `.github/workflows/secret-scan.yml`
- `docs/CICD.md`
- `docs/SUPPLY_CHAIN_SECURITY.md`
