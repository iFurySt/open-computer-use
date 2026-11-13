#!/usr/bin/env bash
# Secret and privacy scan of every commit reachable from HEAD (.gitleaks.toml), with gitleaks pinned by checksum.
# A benign finding is allowed by its fingerprint in .gitleaksignore with its reason; a real one is removed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="8.30.1"

# sha256 values from the release's gitleaks_8.30.1_checksums.txt. Upgrading replaces the version and all four.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="linux_x64" sha="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" ;;
  Linux-aarch64) asset="linux_arm64" sha="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080" ;;
  Darwin-arm64) asset="darwin_arm64" sha="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5" ;;
  Darwin-x86_64) asset="darwin_x64" sha="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709" ;;
  *) echo "check-secrets: no pinned gitleaks for $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
archive="${work}/gitleaks.tar.gz"
curl -fsSL --retry 3 -o "${archive}" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_${asset}.tar.gz"
actual="$( (command -v sha256sum >/dev/null && sha256sum "${archive}") || shasum -a 256 "${archive}")"
if [[ "${actual%% *}" != "${sha}" ]]; then
  echo "check-secrets: gitleaks archive has sha256 ${actual%% *}, but ${sha} is pinned" >&2
  exit 2
fi
tar -xzf "${archive}" -C "${work}" gitleaks

"${work}/gitleaks" git --log-opts=HEAD --config "${repo_root}/.gitleaks.toml" \
  --gitleaks-ignore-path "${repo_root}/.gitleaksignore" --no-banner --redact "${repo_root}"
