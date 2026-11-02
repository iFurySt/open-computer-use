#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/scripts/check-docs.sh"
"${repo_root}/scripts/check-repo-hygiene.sh"
"${repo_root}/scripts/check-action-pinning.sh"
"${repo_root}/scripts/tests/install-dsh-mcp.test.sh"
python3 "${repo_root}/scripts/tests/locked-use-auth-latency.test.py"
python3 "${repo_root}/scripts/tests/locked-use-notarization.test.py"
python3 "${repo_root}/scripts/tests/locked-use-release-packaging.test.py"

while IFS= read -r file; do
  bash -n "$file"
done < <(find "${repo_root}/scripts" -type f -name '*.sh' | sort)

while IFS= read -r file; do
  node --check "$file"
done < <(find "${repo_root}/scripts" -type f -name '*.mjs' | sort)

node --test "${repo_root}"/scripts/node-repl/*.test.mjs "${repo_root}"/scripts/tests/*.test.mjs

(
  cd "${repo_root}/apps/OpenComputerUseLinux"
  python3 -m unittest -v runtime_test.py
)

if command -v go >/dev/null 2>&1; then
  (
    cd "${repo_root}/apps/OpenComputerUseWindows"
    go test ./...
  )
  (
    cd "${repo_root}/apps/OpenComputerUseLinux"
    go test ./...
  )
fi

echo "基础 CI 检查通过"
