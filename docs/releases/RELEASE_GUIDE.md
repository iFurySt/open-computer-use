# 发版指南

这份文档约束这个仓库未来的 patch / minor release 流程，目标是避免再次出现 “git tag 已经发了，但 npm staging 产物版本还是旧值” 这类版本源不一致问题。

## 什么时候必读

- 只要任务里包含这些动作之一，就先读这份文档：
  - bump 版本
  - 打 release tag
  - 推送 release tag
  - 看 GitHub Actions release 失败原因
  - 重发某个失败版本

## 什么时候才发公开版本

- 日常修复、官方 `computer-use` 对齐验证和本地回归，默认只构建本地 app / 二进制并让 MCP client 指向本地构建产物。
- 不要把 patch release 当作普通验证手段；只有用户明确要求公开发版，或某个修复已经达到需要交付给外部用户的稳定状态时，才进入下面的 release checklist。
- 如果只是为了让 Codex 使用最新本地实现，优先更新本机 `~/.codex/config.toml` 中的 `open-computer-use` MCP server command，指向仓库本地构建产物，而不是 bump 版本、打 tag、推 release。

## 当前 release 入口

GitHub 仓库规范地址是 `https://github.com/iFurySt/open-computer-use`。仓库改名不改变三个既有 npm 包名、CLI 别名、App Bundle ID 或签名团队。新 release notes 使用当前地址；校验器仍接受已发布 notes 的旧仓库链接，历史正文不批量改写。兼容性回归可运行 `node --test scripts/tests/release-notes.test.mjs`。

npm staging 的 `repository.url` 必须与发布所在的 GitHub 仓库一致，否则 provenance / Trusted Publishing 可能失败。改名后应逐个核对 `open-computer-use`、`open-computer-use-mcp`、`open-codex-computer-use-mcp` 的 npm Trusted Publisher，workflow 文件仍为 `release.yml`。`npm publish --dry-run` 和 `npm whoami` 不能验证 GitHub OIDC；可在同一 workflow 文件的临时分支上，使用 GitHub OIDC 向 npm 官方 token-exchange API 验证三个包均返回 HTTP 201，不输出、保存或使用返回的 token，不执行 publish。该检查证明认证可用，完整构建 / provenance / 发布仍以实际发版为准。

publisher 即使已绑定仓库不可变身份、页面仍显示 Valid，也不能据此推断改名后的认证可用：本次迁移的旧名称连接在真实 token exchange 中返回 HTTP 404。应以新仓库名新增连接，沿用原有权限，并验证真实认证。创建连接需要账号所有者逐包完成 npm 的安全密钥二步验证。旧名连接保留为迁移记录，下次正式发版成功后可按需清理；它们不能作为新仓库认证的 fallback。参考 [npm 官方 Trusted Publishing 文档](https://docs.npmjs.com/trusted-publishers/)与 [npm Registry API](https://api-docs.npmjs.com/)。

2026-10-17 的迁移已通过 [真实认证复验](https://github.com/iFurySt/open-computer-use/actions/runs/39012120822)：三个包的 token exchange 均返回 HTTP 201，新连接随后从 Pending validation 变为 Valid。该认证复验没有发布新版本或保存返回的 token，当时 npm 版本仍为 1.1.1。后续 [v1.1.2 正式发布](https://github.com/iFurySt/open-computer-use/actions/runs/39012969782) 已验证四个 job 成功、三个包通过 OIDC 发布，新仓库元信息与 provenance 已进入 registry。

- 本地 staging / 打 tgz：`./scripts/release-package.sh`
- 本地重新封装 GitHub Release assets：`./scripts/package-github-release-assets.sh --version <version>`
- 本地构建 Cursor Motion DMG：`./scripts/build-cursor-motion-dmg.sh --configuration release --arch universal --version <version>`
- 本地 stage npm 包目录：`node ./scripts/npm/build-packages.mjs`
- 本地 publish：`node ./scripts/npm/publish-packages.mjs`
- CI workflow：`.github/workflows/release.yml`
- 用户可见发布记录：`docs/releases/feature-release-notes.md`
- GitHub Release 正文：`docs/releases/github/vX.Y.Z.md`
- GitHub Release 页面：workflow 使用审核过的英文 notes 文件创建或更新，不直接引用 PR 标题自动生成正文。

## 参考资料归档 Release

官方 `computer-use` 原始 ZIP 使用独立的 `reference-bundles` tag / Release 分发，下载入口为 `https://github.com/iFurySt/open-computer-use/releases/download/reference-bundles/<filename>`。它只归档研究输入，不属于下面的 patch / minor 软件发版流程，不 bump plugin / npm / App 版本。

- 标记为 pre-release，并显式设置 `--latest=false`，保持正式版本的 latest 下载入口。
- tag 使用不匹配 `v*` 或 `*.*.*` 的固定名称 `reference-bundles`，避免触发应用与 npm release workflow。
- 每个附件先校验 SHA-256 和 ZIP 完整性，上传后从公开固定 URL 重新下载并验证；发布说明使用英文。
- 保留已发布 tag 与文件名，不覆盖既有版本附件；新增版本使用新的文件名，并同步仓库内的下载说明、`SHA256SUMS` 和 Release 中的校验清单。
- 仓库不再跟踪这些 ZIP 或其 LFS 指针。目录说明见[官方参考包](../references/codex-computer-use-reverse-engineering/assets/official-bundles/computer-use/README.md)。

## 当前版本源

这个仓库当前有三类 release 版本源：

- npm staging 包版本：以 `plugins/open-computer-use/.codex-plugin/plugin.json` 里的 `version` 为准。
- GitHub Release 正文：以 `docs/releases/github/<tag>.md` 为准，文件名必须与实际 tag 完全一致。
- `CursorMotion-<version>.dmg` 文件名与 GitHub Release asset 版本：以 release tag 为准；workflow 会把 `vX.Y.Z` 规范化成 `X.Y.Z` 写进 DMG 文件名，也可以在本地显式传 `--version`。
- Open Computer Use direct-download asset 版本：以 plugin manifest 为准；`package-github-release-assets.sh --version` 会拒绝与 manifest 不一致的版本。

也就是说：

- 只改 git tag，不改这个 manifest，不会得到新 npm 版本。
- `scripts/npm/build-packages.mjs` 会从这个 manifest 读取版本，再生成三个 root/alias staging 包；每个包内置 macOS、Linux 和 Windows runtime artifacts。
- 所以 release 前必须先把这份 manifest bump 到目标版本。
- 如果缺少目标 tag 对应的英文 notes，或者 notes 与 manifest/tag 不一致，`release-metadata` job 会在 npm 与 DMG job 启动前失败。
- 如果要让 `CursorMotion` 的 DMG 文件名和 release 页面资产名正确落到目标版本，也必须使用目标 tag 推送，或本地显式传入同样的 `--version`。

## Release Checklist

### 1. 先统一版本号

至少检查并同步这些位置：

- `plugins/open-computer-use/.codex-plugin/plugin.json`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseVersion.swift`
- `apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite/main.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `apps/OpenComputerUseLinux/main.go`
- `apps/OpenComputerUseWindows/main.go`
- `scripts/computer-use-cli/main.go`
- `scripts/computer-use-cli/README.md`
- `docs/releases/feature-release-notes.md`
- `docs/releases/github/vX.Y.Z.md`
- `docs/histories/` 中本轮 release 对应的 history

如果这轮 release 还改了其他对外暴露版本字符串，也要一起对齐，不要只改一半。

### 2. 准备并验证 GitHub Release notes

从 `docs/releases/github/TEMPLATE.md` 创建目标 tag 对应文件，并运行：

```bash
node ./scripts/validate-github-release-notes.mjs --tag v0.1.14
```

校验要求：

- tag 必须是 `vX.Y.Z` 或 `X.Y.Z`，并与 plugin manifest 版本一致。
- 正文以 `## What's Changed` 开头，包含 1-3 条用户可感知的英文变化。
- 正文不能包含 CJK 字符。
- 正文必须且只能包含一个指向当前 tag 的 `Full Changelog` 链接。

任何一项不满足都不要打 tag。tag push 后，`release-metadata` job 会再次执行相同校验，并在失败时阻止 npm 与 DMG job 启动。

### 3. 本地验证版本源已经生效

至少跑这些步骤：

```bash
node ./scripts/validate-github-release-notes.mjs --tag v0.1.14
swift test
node ./scripts/npm/build-packages.mjs --out-dir dist/release/npm-staging-check
./scripts/build-cursor-motion-dmg.sh --configuration release --arch universal --version 0.1.14
./scripts/package-github-release-assets.sh --version 0.1.14
```

然后直接检查 staging 包版本和 DMG 文件名：

```bash
node -p "require('./dist/release/npm-staging-check/open-computer-use/package.json').version"
test -x "dist/release/npm-staging-check/open-computer-use/dist/linux/arm64/open-computer-use"
test -f "dist/release/npm-staging-check/open-computer-use/dist/windows/arm64/open-computer-use.exe"
test -x "dist/release/npm-staging-check/open-computer-use/bin/ocu"
node -e "const bin=require('./dist/release/npm-staging-check/open-computer-use/package.json').bin; if (bin.ocu !== 'bin/ocu') process.exit(1)"
node -e "if (require('./dist/release/npm-staging-check/open-computer-use/package.json').optionalDependencies) process.exit(1)"
ls dist/release/cursor-motion/CursorMotion-0.1.14.dmg
test -f dist/release/github/Open-Computer-Use-0.1.14-macOS-universal.app.zip
test "$(find dist/release/github -maxdepth 1 -type f -name 'open-computer-use-cli-*' | wc -l | tr -d ' ')" = 4
(cd dist/release/github && shasum -a 256 -c SHA256SUMS)
```

如果这里打印的不是目标版本，或者 DMG 没按目标版本名产出，不要打 tag。

如果当前 checkout 里已经有和目标版本一致的 `dist/Open Computer Use.app`，也可以临时加 `--skip-build` 跳过重复构建；但在干净 checkout 里不要默认加这个参数，否则 staging 脚本会因为缺少 `dist/Open Computer Use.app` 而失败。

### 4. 提交版本 bump

- 用单独 commit 提交 release version bump。
- commit message 要能直接看出这是 release 收口，而不是普通功能提交。

### 5. 打 tag 并推送

当前约定用 `vX.Y.Z`：

```bash
git tag -a v0.1.14 -m "v0.1.14"
git push origin main
git push origin v0.1.14
```

tag push 后，`.github/workflows/release.yml` 会自动完成：

- 发布 npm 包。
- 构建 Open Computer Use 的 macOS app、Linux / Windows CLI 与 skill 直接下载包。
- 构建 `CursorMotion-0.1.14.dmg`。
- 等全部构建 job 成功后，一次性创建或更新同名 tag 的 GitHub Release assets。

### 6. 检查 GitHub Release notes

每次 tag push 后都要检查 GitHub Release 页面，不要只确认 workflow 绿了：

```bash
gh release view v0.1.14 --json body,url
```

workflow 会使用 `docs/releases/github/<tag>.md` 创建新 Release；如果 Release 已经存在，则覆盖上传 macOS app、Linux / Windows CLI、skill、checksums、manifest 和 DMG，并用同一文件更新正文。GitHub 自动生成 notes 不再是正文来源，因此 PR 标题使用中文也不会改变公开 Release 的语言。

最低要求：

- release body 必须与仓库里的目标 notes 文件一致。
- `What's Changed` 必须列出本次用户可感知的 1-3 个英文变化。
- 保留 `Full Changelog` 链接。

## Release 失败时怎么查

### 1. 先看最新 run

```bash
gh run list -R iFurySt/open-computer-use --limit 10
gh run view -R iFurySt/open-computer-use <run-id> --log-failed
```

### 2. 重点看哪一类错误

- `release-metadata` 失败
  - 先本地运行 `node ./scripts/validate-github-release-notes.mjs --tag <tag>`。
  - 检查 `docs/releases/github/<tag>.md` 是否存在、manifest 版本是否匹配、正文是否包含 CJK，以及 Full Changelog 是否指向当前 tag。
- `npm error 403 ... You cannot publish over the previously published versions`
  - 通常不是 token 权限问题，而是 staging 包版本仍然是旧版本。
  - 先回头检查 `plugin.json` 的 `version`，再检查 staging 包实际产出的 `package.json`。
- `npm error 404 Not Found - PUT https://registry.npmjs.org/<package>`
  - 先确认 registry 上目标包旧版本是否仍可见：`npm view <package> versions --json`。
  - 当前 publish 脚本会在发布前跳过已经存在的同版本 package，并对 publish 失败做短暂重试；如果 GitHub Actions OIDC 可用，会优先用 `--provenance` 走 trusted publishing，再回退到 `NODE_AUTH_TOKEN`。如果 tag 重发前某个 package 已经部分发布成功，重新跑同一个 release 不会因为该 package 已存在而中断。
- `npm error need auth ... You need to authorize this machine using npm adduser`
  - 如果日志显示已经选择 `GitHub Actions OIDC trusted publishing`，优先检查 CI 里的 npm CLI 版本；trusted publishing 需要 npm `11.5.1+`，当前 release workflow 的 npm package job 使用 Node `24` 并显式检查 npm 版本。
  - 如果 npm CLI 版本满足要求仍报这个错误，说明 npmjs.com 包侧还没有把当前 GitHub repo / workflow 文件配置成 trusted publisher。
- 发布成功后，`npm view` 仍显示旧版本或目标版本返回 404
  - 先核对 CI 中每个包的 publish 成功日志。registry 元数据的 CDN 响应可能带有 `max-age=300`，短时间内仍返回旧内容；`--prefer-online` 也可能读到同一份边缘缓存。
  - 可通过 `https://registry.npmjs.org/-/package/<package-name>/dist-tags` 核对实时 dist-tag；待缓存刷新后，再确认三个包的目标版本和 `latest` 一致，避免把传播延迟误判为发布失败。
  - v1.1.2 曾出现 tarball 已返回 HTTP 200，但版本元数据仍返回 404 的传播窗口。可只读核对带唯一查询参数的完整 packument 辅助定位，最终仍以普通 `npm view` 与实际安装确认，不能用单个缓存响应判断需要重发。
- `gh attestation verify` 提示 `unsupported tlog public key type: PKIX_ED25519`
  - 先用新版官方 GitHub CLI 复验。此次本机 `gh 2.49.0` 无法读取新的 Sigstore trusted root，而临时下载并核对官方 archive digest 的 `gh 2.102.0` 验证同一制品成功；旧验证器的不兼容不能据此判定 Release 签名失效。复验应同时限制 `--repo iFurySt/open-computer-use` 与 `--signer-workflow iFurySt/open-computer-use/.github/workflows/release.yml`。
- 构建阶段失败
  - 优先看 `Build npm release artifacts`、`package-github-release-assets.sh` 的架构/归档校验、`Build Cursor Motion DMG` 或 Swift 编译错误。
- GitHub Release 资产上传失败
  - 优先看 `publish-github-release` job，确认两个上游 artifact 都已上传、tag 存在、`GH_TOKEN` 权限正常，以及下载后的 asset 路径匹配。
- publish 认证失败
  - 再去看 `.github/workflows/release.yml`、`scripts/npm/publish-packages.mjs` 和 npm trusted publishing / token fallback 配置。

## 当前已知边界

- `Open Computer Use` 的正式 npm / 直接下载制品需要配置 `OPEN_COMPUTER_USE_CODESIGN_P12_BASE64` / `OPEN_COMPUTER_USE_CODESIGN_P12_PASSWORD`；导入 Developer ID 身份后按同一 team 签名主 App 与 Locked Use 组件。缺少签名时正式发布失败；日常无签名构建可显式关闭 Locked Use 嵌入。
- 如果 Open Computer Use 已使用 Developer ID 签名且 `APPLE_NOTARY_*` secrets 齐全，workflow 会先公证 Locked Use payload，并为授权 bundle / Guardian 附票据，再重签、公证并 staple 外层 `.app`，最后无重编译地刷新 npm 包、app zip、checksums 和 manifest；缺少任一条件时跳过 notarization。嵌套组件位于外层资源封印中，不能只在现有外层签名后 staple 子组件。发布前应核对 npm 解包后的授权 bundle 也通过 `stapler validate`，并完成安装后的冷 / 热解锁对比，详见 [冷加载诊断](../references/macos-locked-use-cold-auth-latency.md)。
- `Cursor Motion` 当前 release 资产会优先复用 `OPEN_COMPUTER_USE_CODESIGN_*` 对 app 做 `Developer ID Application` 签名；如果同时配置 `APPLE_NOTARY_API_KEY_P8_BASE64`、`APPLE_NOTARY_KEY_ID`、`APPLE_NOTARY_ISSUER_ID`、`APPLE_DEVELOPER_TEAM_ID`，workflow 会继续对 `.dmg` 执行 notarization 和 staple。
- Open Computer Use 的正式发布必须包含 Locked Use 签名组件，缺少 Apple 签名身份时构建失败，不能静默发布不完整的 App；公证凭据缺失仍可跳过 notarization。
- 签名 release App 默认自动构建并内嵌与主 App 同架构的 Locked Use 组件；支持 native / arm64 / x86_64 / universal。CI 显式设置 OPEN_COMPUTER_USE_INCLUDE_LOCKED_USE=1，制品检查覆盖四个组件的架构和严格嵌套签名。
- `open-computer-use` npm root 包会内置六个 `os-arch` native artifacts，包体积会比 macOS-only 版本更大；release 前要确认 staging 包里包含 `dist/Open Computer Use.app`、`dist/linux/` 和 `dist/windows/`，并确认 launcher 没有声明 `optionalDependencies`。
- 直接下载的 Linux / Windows CLI archive 只包含 native CLI / MCP runtime；`ocu js` / `ocu repl` 所需的 Node adapter 继续通过 npm 包分发。
- macOS direct download 必须保留完整 `.app` bundle；不要单独分发 `Contents/MacOS/OpenComputerUse`，否则无法可靠复用 app-scoped 权限身份。

## 如果 tag 已经打错了

如果远端 tag 已经指向错误 commit，先删 tag，再修版本源，再重打。

本地删 tag：

```bash
git tag -d v0.1.14
```

远端删 tag：

```bash
git push origin :refs/tags/v0.1.14
```

修好后再重新创建并推送同名 tag。

## 文档同步要求

每次 release 都至少同步这三类文档：

- `docs/releases/feature-release-notes.md`
- `docs/releases/github/vX.Y.Z.md`
- `docs/histories/` 对应 release history
- 如果 release 流程本身有变化，这份 `docs/releases/RELEASE_GUIDE.md`

如果一次 release 暴露出新的流程坑，就不要只在聊天里记住，直接补进这份文档。

Locked Use 组件签名同样必须在 CI 临时 signing keychain 可搜索的上下文中执行；仅传 codesign --keychain 不能替代现有的临时搜索列表处理。helper 在成功和失败时均恢复列表，scripts/tests/locked-use-signing.test.sh 用模拟 keychain 回归此边界，不触碰真实用户 keychain。

主 App 与 Locked Use 组件显式以 `codesign --options runtime,library` 签名，确保运行时有 `CS_REQUIRE_LV`；仅启用 Hardened Runtime 不能替代进程校验要求的 Library Validation 标志。构建时 kernel verifier 正例必须通过，不能跳过或放宽生产 requirement。
