#!/usr/bin/env bash
# Read-only release validation: every runtime component matches the main App.
set -euo pipefail
app="${1:?Usage: scripts/verify-locked-use-bundle.sh APP}"
base="$app/Contents/Resources/LockedUse"
app_architectures="$(lipo -archs "$app/Contents/MacOS/OpenComputerUse")"
read -r -a architectures <<< "$app_architectures"
[[ "${#architectures[@]}" -gt 0 ]]
team="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Locked Use release requires an Apple signing team.' >&2; exit 1; }
[[ -d "$base" ]] || { echo 'Locked Use runtime is missing from the App.' >&2; exit 1; }
[[ "$(find "$base" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 4 ]] || { echo 'Unexpected Locked Use runtime components.' >&2; exit 1; }
components=(OCULockService OCULockInstaller 'OCU Guardian.app' OCULockAuth.bundle)
executables=(OCULockService OCULockInstaller 'OCU Guardian.app/Contents/MacOS/OCUGuardian' 'OCULockAuth.bundle/Contents/MacOS/OCULockAuth')
identifiers=(dev.opencomputeruse.locked-use.broker dev.opencomputeruse.locked-use.installer dev.opencomputeruse.locked-use.guardian.dev dev.opencomputeruse.locked-use.authorization)
for index in 0 1 2 3; do
  [[ -x "$base/${executables[$index]}" ]]
  for arch in "${architectures[@]}"; do
    lipo "$base/${executables[$index]}" -verify_arch "$arch"
  done
  codesign --verify --strict -R "=identifier \"${identifiers[$index]}\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$base/${components[$index]}"
done
codesign --verify --deep --strict "$app"
echo "Locked Use bundle verified: ${architectures[*]}, four signed runtime components."
