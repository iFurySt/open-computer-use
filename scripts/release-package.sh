#!/usr/bin/env bash

set -euo pipefail

# These entry points select the release/dev payload by configuration, not variant.
# An inherited dev override could leave an old release bundle selected for delivery.
if [[ -n "${OPEN_COMPUTER_USE_APP_VARIANT:-}" ]]; then
  echo 'OPEN_COMPUTER_USE_APP_VARIANT is only supported by build-open-computer-use-app.sh; unset it before packaging or installing.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${repo_root}/dist"
release_dir="${dist_dir}/release"
staging_dir="${release_dir}/npm-staging"
tarball_dir="${release_dir}/npm"

build_args=(--configuration release --arch universal --out-dir "${staging_dir}")
if [[ $# -eq 1 && "$1" == --skip-build ]]; then
  build_args+=(--skip-build)
elif [[ $# -ne 0 ]]; then
  echo 'Usage: scripts/release-package.sh [--skip-build]' >&2
  exit 64
fi

rm -rf "${release_dir}"
mkdir -p "${tarball_dir}"

node "${repo_root}/scripts/npm/build-packages.mjs" "${build_args[@]}"

"${repo_root}/scripts/package-github-release-assets.sh"

while IFS= read -r package_dir; do
  npm pack "${package_dir}" --pack-destination "${tarball_dir}" >/dev/null
done < <(find "${staging_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

python3 - "${release_dir}/release-manifest.json" "${repo_root}" "${tarball_dir}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
tarball_dir = Path(sys.argv[3])

artifacts = []
for tarball in sorted(tarball_dir.glob("*.tgz")):
    artifacts.append({
        "name": tarball.name,
        "size_bytes": tarball.stat().st_size,
    })

manifest = {
    "repository": os.environ.get("GITHUB_REPOSITORY", "local"),
    "git_sha": os.environ.get("GITHUB_SHA") or __import__("subprocess").check_output(
        ["git", "-C", str(repo_root), "rev-parse", "HEAD"],
        text=True,
    ).strip(),
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "artifacts": artifacts,
    "github_release_assets": "dist/release/github/release-assets-manifest.json",
    "distribution": {
        "type": "npm",
        "package_count": len(artifacts),
        "staging_dir": str(tarball_dir.relative_to(repo_root)),
    },
}

manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

echo "${release_dir}"
