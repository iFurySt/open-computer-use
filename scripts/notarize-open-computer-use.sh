#!/usr/bin/env bash
# Notarize the installable payload before sealing and notarizing its container.
set -euo pipefail
if [[ $# -lt 2 ]]; then
  echo 'Usage: scripts/notarize-open-computer-use.sh APP <notarytool authentication options...>' >&2
  exit 64
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/locked-use-build-common.sh"
app="$1"
shift
identity="${OPEN_COMPUTER_USE_CODESIGN_IDENTITY:?Developer ID identity is required}"
[[ "$identity" != - ]] || exit 64
payload="$app/Contents/Resources/LockedUse"
"$repo_root/scripts/verify-locked-use-bundle.sh" "$app"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ocu-notarize.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

submit() {
  local archive="$1" result="$2"
  shift 2
  xcrun notarytool submit "$archive" "$@" --wait --output-format json > "$result"
  python3 - "$result" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    result = json.load(source)
print("Notarization status:", result.get("status", "unknown"))
if result.get("status") != "Accepted":
    sys.exit("Notarization did not accept this submission; packaging stopped.")
PY
}

# Each of these bundles is copied outside the main App by our installer.
# A ticket stapled only to the outer App does not travel with that copy.
ditto -c -k --keepParent "$payload" "$scratch/payload.zip"
submit "$scratch/payload.zip" "$scratch/payload-result.json" "$@"
for component in OCULockAuth.bundle 'OCU Guardian.app'; do
  xcrun stapler staple "$payload/$component"
  xcrun stapler validate "$payload/$component"
done

# Contents/Resources is sealed as resources. Stapling its children changes
# that seal; re-sign only the outer App, preserving its identity/entitlements.
locked_use_sign --force --sign "$identity" --timestamp \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$scratch/app.zip"
submit "$scratch/app.zip" "$scratch/app-result.json" "$@"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
"$repo_root/scripts/verify-locked-use-bundle.sh" "$app"
