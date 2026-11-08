#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  ".gitignore"
  ".gitattributes"
  "CODEOWNERS"
  "CONTRIBUTING.md"
  "SECURITY.md"
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  "scripts/check-action-pinning.sh"
)

failed=0

for path in "${required_files[@]}"; do
  if [[ ! -f "${repo_root}/${path}" ]]; then
    echo "缺少必要文件: ${path}"
    failed=1
  fi
done

if grep -q $'\r' "${repo_root}/README.md"; then
  echo "README.md 含有 CRLF 换行"
  failed=1
fi

if ! grep -q "make check-docs" "${repo_root}/CONTRIBUTING.md"; then
  echo "CONTRIBUTING.md 应明确提到 make check-docs"
  failed=1
fi

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi

echo "仓库基础卫生检查通过"
