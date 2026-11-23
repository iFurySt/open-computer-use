#!/usr/bin/env bash
# Build only. Installing/starting the privileged service is a separate step.
set -euo pipefail
identity=""
configuration="debug"
arch_mode="native"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) identity="${2:?Missing signing identity}"; shift 2 ;;
    --configuration) configuration="${2:?Missing configuration}"; shift 2 ;;
    --arch) arch_mode="${2:?Missing architecture}"; shift 2 ;;
    *) echo 'Usage: scripts/build-locked-use-components.sh --identity ID [--configuration debug|release] [--arch native|arm64|x86_64|universal]' >&2; exit 64 ;;
  esac
done
[[ -n "$identity" && "$identity" != - ]] || exit 64
[[ "$configuration" == debug || "$configuration" == release ]] || exit 64
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/locked-use-build-common.sh"
locked_use_architectures
output="$repo_root/.build/locked-use/components"
guardian_source=".build/locked-use/OCU Guardian (Dev).app"
if [[ "$configuration" == release ]]; then
  output="$repo_root/.build/locked-use/components-release"
  guardian_source=".build/locked-use/release/OCU Guardian.app"
fi
if [[ "$arch_mode" != native ]]; then
  output="$output-$arch_mode"
  guardian_source="$(dirname "$guardian_source")-$arch_mode/$(basename "$guardian_source")"
fi
mkdir -p "$output"
locked_use_build_product OCULockService "$output/OCULockService"
locked_use_build_product OCULockInstaller "$output/OCULockInstaller"
locked_use_sign --force --options runtime,library --timestamp --identifier dev.opencomputeruse.locked-use.installer \
  --sign "$identity" "$output/OCULockInstaller"
locked_use_sign --force --options runtime,library --timestamp --identifier dev.opencomputeruse.locked-use.broker \
  --sign "$identity" "$output/OCULockService"
team="$(codesign -dv --verbose=4 "$output/OCULockService" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then echo 'Developer ID team unavailable.' >&2; exit 1; fi
scripts/build-locked-use-guardian.sh --identity "$identity" --configuration "$configuration" --arch "$arch_mode"
ditto "$guardian_source" "$output/$(basename "$guardian_source")"
bundle="$output/OCULockAuth.bundle"
mkdir -p "$bundle/Contents/MacOS"
native_arch="$(uname -m)"
plugin_binaries=()
for arch in "${architectures[@]}"; do
  objects="$output/plugin-$arch"
  mkdir -p "$objects"
  xcrun swiftc -parse-as-library -emit-object -target "$arch-apple-macos14.0" \
    -module-name OCULockedUseTaskVerifier experiments/LockedUse/AuthorizationPlugin/TaskVerifier.swift \
    -o "$objects/task-verifier.o"
  xcrun clang -target "$arch-apple-macos14.0" -fobjc-arc -std=gnu11 -Wall -Wextra -Werror -fvisibility=hidden \
    "-DOCU_SIGNING_TEAM=\"$team\"" -I packages/LockedUseNative/include -c \
    experiments/LockedUse/AuthorizationPlugin/RemotePlugin.m -o "$objects/remote-plugin.o"
  xcrun clang -target "$arch-apple-macos14.0" -std=gnu11 -Wall -Wextra -Werror \
    -I packages/LockedUseNative/include -c packages/LockedUseNative/PeerIdentity.c -o "$objects/plugin-peer.o"
  xcrun swiftc -emit-library -Xlinker -bundle -target "$arch-apple-macos14.0" \
    -framework Security -framework Foundation -lbsm \
    "$objects/remote-plugin.o" "$objects/plugin-peer.o" "$objects/task-verifier.o" \
    -o "$objects/OCULockAuth"
  plugin_binaries+=("$objects/OCULockAuth")
done
if [[ "${#plugin_binaries[@]}" == 1 ]]; then
  cp "${plugin_binaries[0]}" "$bundle/Contents/MacOS/OCULockAuth"
else
  lipo -create -output "$bundle/Contents/MacOS/OCULockAuth" "${plugin_binaries[@]}"
fi
for arch in "${architectures[@]}"; do
  lipo "$bundle/Contents/MacOS/OCULockAuth" -verify_arch "$arch"
done
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.opencomputeruse.locked-use.authorization</string>
<key>CFBundleExecutable</key><string>OCULockAuth</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>${locked_use_version}</string>
</dict></plist>
PLIST
locked_use_sign --force --options runtime,library --timestamp --sign "$identity" "$bundle"
codesign --verify --strict "$bundle"
codesign --verify --strict "$output/OCULockService"
if [[ " ${architectures[*]} " == *" $native_arch "* ]]; then
xcrun clang -std=c11 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -framework Security \
  experiments/LockedUse/AuthorizationPlugin/RemotePluginTests.c -o "$output/remote-plugin-abi-tests"
"$output/remote-plugin-abi-tests" "$bundle/Contents/MacOS/OCULockAuth"
# Exercise the modern kernel verifier against independently signed live code.
# These executables are diagnostic artifacts, never installed or used as peers.
# Fresh inodes prevent kernel signature caches from seeing an in-place update.
test_output="$(mktemp -d "$output/task-verifier-checks.XXXXXX")"
xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 "-DOCU_SIGNING_TEAM=\"$team\"" -c \
  experiments/LockedUse/AuthorizationPlugin/TaskVerifierTests.c -o "$test_output/task-verifier-tests.o"
xcrun swiftc -parse-as-library -emit-object -target "$native_arch-apple-macos14.0" \
  -module-name OCUTaskVerifierDiagnostics experiments/LockedUse/AuthorizationPlugin/TaskVerifierDiagnostics.swift \
  -o "$test_output/task-verifier-diagnostics.o"
xcrun swiftc -target "$native_arch-apple-macos14.0" "$test_output/task-verifier-diagnostics.o" "$test_output/task-verifier-tests.o" "$output/plugin-$native_arch/task-verifier.o" \
  -o "$test_output/task-verifier-tests"
locked_use_sign --force --options runtime,library --timestamp --identifier dev.opencomputeruse.locked-use.broker \
  --sign "$identity" "$test_output/task-verifier-tests"
authority="$(codesign -dv --verbose=4 "$test_output/task-verifier-tests" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
if [[ "$authority" == 'Developer ID Application:'* ]]; then
  echo 'Task verifier diagnostic signer: Developer ID Application'
else
  echo 'Task verifier diagnostic signer: not Developer ID Application'
fi
"$test_output/task-verifier-tests" match
rm -f "$test_output/task-verifier-wrong-id"
cp "$test_output/task-verifier-tests" "$test_output/task-verifier-wrong-id"
locked_use_sign --force --options runtime,library --timestamp --identifier dev.opencomputeruse.locked-use.wrong \
  --sign "$identity" "$test_output/task-verifier-wrong-id"
"$test_output/task-verifier-wrong-id" reject
rm -f "$test_output/task-verifier-adhoc"
cp "$test_output/task-verifier-tests" "$test_output/task-verifier-adhoc"
locked_use_sign --force --options runtime,library --identifier dev.opencomputeruse.locked-use.broker --sign - "$test_output/task-verifier-adhoc"
"$test_output/task-verifier-adhoc" reject
cat > "$test_output/task-verifier-debug.plist" <<PLIST
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
rm -f "$test_output/task-verifier-debug"
cp "$test_output/task-verifier-tests" "$test_output/task-verifier-debug"
locked_use_sign --force --options runtime,library --timestamp --identifier dev.opencomputeruse.locked-use.broker \
  --entitlements "$test_output/task-verifier-debug.plist" --sign "$identity" "$test_output/task-verifier-debug"
"$test_output/task-verifier-debug" reject
else
  echo 'Cross-target build: runtime ABI tests require a matching host architecture.'
fi
echo 'Signed Broker, Guardian and remote plugin built. No system files or authorization rules changed.'

if [[ "$configuration" == debug ]]; then
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
fixture="$output/OCU Lock Demo (Dev).app"
mkdir -p "$fixture/Contents/MacOS"
cp "$binary_dir/OCUGuardian" "$fixture/Contents/MacOS/OCUGuardian"
cat > "$fixture/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.opencomputeruse.locked-use.fixture.dev</string>
<key>CFBundleExecutable</key><string>OCUGuardian</string>
<key>CFBundleName</key><string>OCU Lock Demo</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
locked_use_sign --force --options runtime,library --timestamp --sign "$identity" "$fixture"

fi
