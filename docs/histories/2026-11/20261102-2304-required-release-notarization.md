## [2026-11-02 23:04] | Task: 要求正式发布完成签名与公证

### Execution Context
- Agent: Codex
- Runtime: Codex desktop

### User Query
> 补充一个 PR，封闭正式发布缺少公证凭据或手动发布跳过公证的路径。

### Changes Overview
- tag 与手动 npm 发布使用相同的公证条件；缺少凭据或 Developer ID 身份立即失败。
- Open Computer Use 与 Cursor Motion 的签名准备均拒绝缺少证书；DMG 公证显式检查 Accepted，staple 后 validate。
- 手动只构建仍可跳过公证；本地开发构建不受本次 workflow 修改影响。
- 新增隔离回归，执行 workflow 真实 shell，覆盖每个缺失凭据、ad-hoc、提交拒绝 / 工具失败、重打包失败及成功顺序；接入现有分发 CI。
- 同步 CI/CD、release guide、冷加载诊断说明与功能记录；没有 bump 版本或实际发布。

### Design Intent
公证被跳过不能等同于公证成功；所有 CI 发布入口都必须执行相同验证。保留已有 npm 与 DMG 独立 job 的结构，DMG 失败会阻止 GitHub Release，不改变已完成 npm 发布的独立性。

### Validation
- 新发布门槛回归 7 项、公证编排 3 项、真实归档票据保留 2 项通过。
- 文档骨架、Action SHA 固定、YAML 解析与 diff 空白检查通过。
- `check-repo-hygiene.sh` 未通过：main 已缺少模板清单中的 `.editorconfig`、PR / issue 模板及旧 CI 文件；本次未引入这些缺失，也未扩大范围恢复模板。
- 测试使用模拟 Apple 工具，不读取真实凭据、访问 keychain 或提交 Apple 公证；实际公证仍需正式发布验证。

### Files Modified
- `.github/workflows/release.yml`
- `.github/workflows/locked-use-distribution.yml`
- `scripts/tests/locked-use-release-policy.test.py`
- `scripts/ci.sh`
- `docs/CICD.md`
- `docs/releases/RELEASE_GUIDE.md`
- `docs/references/macos-locked-use-cold-auth-latency.md`
- `docs/releases/feature-release-notes.md`
