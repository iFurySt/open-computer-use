# CI/CD 说明

这个模板自带一套不依赖具体语言栈的 CI/CD 骨架。

## 当前 release 入口

- `scripts/release-package.sh`：构建 universal `Open Computer Use.app`，cross-compile Linux / Windows runtime，stage 三个既有 root/alias npm 包；每个包都会内置 macOS app、Linux binaries 和 Windows exes，并暴露 `open-computer-use` / `ocu` 等 npm bin 入口。脚本同时调用 `scripts/package-github-release-assets.sh`，产出 npm tarballs、GitHub Release 直接下载制品与对应 manifest。正式 release 必须使用 Apple 签名身份并内嵌四个同团队、同架构的 Locked Use 组件；本地 debug/dev 构建可显式关闭 Locked Use 嵌入以使用 ad-hoc signing。
- `scripts/package-github-release-assets.sh`：把已构建的 universal `.app`、Linux 双架构 binary、Windows 双架构 `.exe` 和 `open-computer-use` skill 封装到 `dist/release/github/`，并生成 `SHA256SUMS` 与 `release-assets-manifest.json`。macOS 必须分发完整 app bundle，不能把 bundle 内 binary 当成独立安装包。
- `scripts/build-cursor-motion-dmg.sh`：本地构建 `Cursor Motion.app` 并封装 `dist/release/cursor-motion/CursorMotion-<version>.dmg`，支持 `native` / `arm64` / `x86_64` / `universal`。
- `scripts/build-open-computer-use-linux.sh`：本地构建实验性 Linux `open-computer-use` binary，支持 `arm64` / `amd64`；release package 会把这两个产物内置进既有 npm 包的 `dist/linux/`。
- `scripts/build-open-computer-use-windows.sh`：本地构建实验性 Windows `open-computer-use.exe`，支持 `arm64` / `amd64`；release package 会把这两个产物内置进既有 npm 包的 `dist/windows/`。
- `.github/workflows/release.yml`：支持 push semver tag 自动发布，也支持手动触发；tag push 时会并行构建 npm/direct-download artifacts 与 `Cursor Motion` DMG，只有两个构建 job 都成功后，单一汇总 job 才会创建或更新 GitHub Release 并上传全套 assets。`Open Computer Use` 的 npm 与 app 正式制品需要 `OPEN_COMPUTER_USE_CODESIGN_*` secrets；workflow 导入 `Developer ID Application` 证书，以同一 identity 对主 App 与四个 Locked Use 组件签名并检查，缺少身份时构建失败。若同时配置 `APPLE_NOTARY_*` secrets，先通过 `scripts/notarize-open-computer-use.sh` 公证 Locked Use 安装组件、为授权 bundle 和 Guardian 附票据，再重签、公证并 staple 主 App。最后用 `scripts/release-package.sh --skip-build` 刷新 npm staging、tarballs 和直接下载制品，避免分发公证前的副本；`Cursor Motion` DMG 也会走 notarization 和 staple。

公证流程的离线编排回归：`python3 scripts/tests/locked-use-notarization.test.py`。票据经真实 staging、三个 npm 包与直接下载 ZIP 打包的回归：`python3 scripts/tests/locked-use-release-packaging.test.py`。这两项已接入 `scripts/ci.sh`，也由 `.github/workflows/locked-use-distribution.yml` 在相关 PR 和 main 变更上独立运行。

workflow 显示名为 `locked-use-distribution-tests`，只是测试入口，不新增发行包或发布渠道；触发范围包含 npm staging、直接下载打包脚本及其输入。

测试使用微型预构建文件，运行仓库真实 staging / 归档脚本，仅替代 macOS 的 `codesign`、`lipo` 和 `ditto`，检查三个包中的主 App / 授权插件 / Guardian 票据字节、旧 staging 清理及制品 manifest；缺失预构建 runtime 时必须停止。不会向 Apple 提交软件或修改本机认证配置。签名、资源封印和真实认证加载仍须另外验证，见 [Locked Use 冷加载诊断](references/macos-locked-use-cold-auth-latency.md)。

`OPEN_COMPUTER_USE_APP_VARIANT=dev` 仅供直接构建优化后的开发身份 App。release / npm 打包和插件安装会在构建、清理或复制前拒绝此变量，需先 unset；避免 Dev 构建保留了旧正式包后误分发旧包。隔离回归：`node --test scripts/tests/app-variant.test.mjs`，已接入分发 workflow。

## 设计原则

这套默认流水线的目标，是在项目真正成形前先把交付链路搭起来，而不是假装已经知道未来项目该怎么 build 和 deploy。

当新项目的技术栈确定后，你应该继续在 `scripts/release-package.sh` 这条真实构建链路上扩展，而不是另起一套平行流程。

所有 GitHub Actions 都已经 pin 到 commit SHA。后续升级 action 时，也要继续保持这个约束。

## Windows 观察与输入回归

`.github/workflows/windows-observation.yml` 在相关 PR 上运行 Windows Go 测试、PowerShell 生产采集函数测试，以及独立 WPF / native MCP smoke，也支持手动触发。工作流仅需 `contents: read`，沿用固定 SHA 的 checkout / setup-node / setup-go，不发布制品。桌面 smoke 使用自己的窗口，验证采集开关、索引与 UIA 设值，以及正常 / 1x1 / 最小化 / cloaked 窗口的截图边界。输入回归另外验证默认窗口消息滚动、四向物理滚轮、点击 / 拖拽 / 组合键和 stale / 遮挡拒绝，并运行 PowerShell 故障注入测试检查释放保护。复现命令见 [按需观察](selective-observation.md)与 [Windows 输入](windows-input.md)。

## 推荐接入顺序

1. 保留 `ci.yml`，作为仓库的基础门禁。
2. 在 `scripts/ci.sh` 里继续叠加项目自己的验证命令。
3. 在 `scripts/release-package.sh` 已有的真实构建基础上继续扩展 release 产物。
4. 技术栈和环境稳定后，再补具体的部署 job。
5. 即使交付方式变化，SBOM 和 provenance 这类供应链能力也建议保留。

## 默认 release 产物

当前 release 流水线会产出：

- `dist/release/release-manifest.json`
- `dist/release/npm/open-computer-use-<version>.tgz`
- `dist/release/npm/open-computer-use-mcp-<version>.tgz`
- `dist/release/npm/open-codex-computer-use-mcp-<version>.tgz`
- `dist/release/github/Open-Computer-Use-<version>-macOS-universal.app.zip`
- `dist/release/github/open-computer-use-cli-<version>-linux-{arm64,amd64}.tar.gz`
- `dist/release/github/open-computer-use-cli-<version>-windows-{arm64,amd64}.zip`
- `dist/release/github/open-computer-use-skill.zip`
- `dist/release/github/open-computer-use.skill`
- `dist/release/github/SHA256SUMS`
- `dist/release/github/release-assets-manifest.json`
- `dist/release/cursor-motion/CursorMotion-<version>.dmg`
- GitHub Actions 中上传的 npm 与 direct-download release artifacts
- GitHub Releases 中上述 direct-download assets 与和 tag 对齐的 `CursorMotion-<version>.dmg`

也就是说，即使项目还没进入更复杂的部署阶段，仓库现在也同时具备 npm 分发链路，以及由 git tag 驱动、覆盖 macOS / Linux / Windows 和 skill 的直接下载链路。
