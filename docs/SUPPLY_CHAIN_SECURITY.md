# 供应链安全

这份文档定义模板默认采用的供应链安全做法。

## 默认控制项

- 在 Pull Request 上做依赖变更审查。
- 用 OSV 对仓库中的依赖声明和 lockfile 做漏洞扫描。
- 为 release 产物生成 SBOM。
- 为 release 产物生成 build provenance attestation。
- 用 OpenSSF Scorecard 做仓库级安全姿态分析。
- 所有 GitHub Actions 都固定到不可变的 commit SHA，而不是漂移的版本标签。

## 当前对应关系

- `actions/dependency-review-action`：阻止 PR 引入高风险依赖变更。
- `google/osv-scanner-action`：根据仓库里的依赖文件扫描已知漏洞。
- `anchore/sbom-action`：生成 SPDX 格式的 SBOM。
- `actions/attest-build-provenance`：为 release artifact 生成签名 provenance。
- `ossf/scorecard-action`：分析仓库级安全信号，例如工作流权限、分支保护等。
- `scripts/check-action-pinning.sh`：如果 workflow 里出现浮动 tag 而不是 SHA，直接让 CI 失败。
- `scripts/check-secrets.sh`：用按 sha256 固定的 gitleaks 扫描每个 commit 里的凭据和隐私信息，见 [CI/CD 说明](CICD.md)。

## 限制和前提

- Dependency Review 在 public repo 可以直接使用；private repo 通常需要 GitHub Advanced Security 或对应的代码安全能力。
- OSV 和 SBOM 的效果依赖仓库里存在可识别的依赖清单或 lockfile。
- 只有当 `scripts/release-package.sh` 真的代表项目的构建产物时，provenance 才真正有意义。
- Scorecard 的结果也依赖仓库本身是否开启了分支保护、工作流权限收敛等真实配置。

## 项目落地后建议继续做的事

- 锁定并提交项目真实依赖的 lockfile。
- 让构建过程尽量可重复、可验证。
- 如果条件允许，在部署链路里增加对 provenance 的校验。
- 把 attestation 校验继续下沉到部署平台或准入层。

## Screenshot WebP codec

macOS SwiftPM pins SDWebImage/libwebp-Xcode to libwebp 1.6.0 with a committed Package.resolved revision. The encoder links into the native executable; no Homebrew codec is required. BSD notices are retained in THIRD_PARTY_NOTICES.md and copied into app Resources and npm packages. Dependency/SBOM review must include this native dependency.
