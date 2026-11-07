#!/usr/bin/env python3
"""Build a real-device monitor probe without locks, input synthesis or key values.

A stable signing identity can reuse the normal Guardian's Input Monitoring grant.
The fixture is isolated in .build and never replaces an installed app.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-identity')
    parser.add_argument('--seconds', type=int, choices=range(1, 61), default=5)
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--baseline-ref')
    parser.add_argument('--panel', action='store_true')
    args = parser.parse_args()
    folder = 'baseline' if args.baseline_ref else 'current'
    app = ROOT / '.build/input-monitor-smoke' / folder / 'OCU Input Monitor Test.app'
    binary = app / 'Contents/MacOS/OCUGuardian'
    binary.parent.mkdir(parents=True, exist_ok=True)
    plist = {'CFBundleIdentifier': 'dev.opencomputeruse.locked-use.guardian.dev',
             'CFBundleExecutable': 'OCUGuardian', 'CFBundleName': 'OCU Input Monitor Test',
             'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True,
             'NSInputMonitoringUsageDescription': 'Verify input activity counts without reading key values.'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
    source = ROOT / 'experiments/LockedUse/Sources/Guardian'
    with tempfile.TemporaryDirectory(prefix='ocu-monitor-source-') as temp:
        files = [source / 'PhysicalInputMonitor.swift', source / 'NativePhysicalInputBackend.swift']
        if args.baseline_ref:
            files = []
            for name in ['PhysicalInputMonitor.swift', 'NativePhysicalInputBackend.swift']:
                result = subprocess.run(['git', 'show', f'{args.baseline_ref}:experiments/LockedUse/Sources/Guardian/{name}'],
                                        cwd=ROOT, capture_output=True, text=True)
                if result.returncode and name == 'NativePhysicalInputBackend.swift':
                    continue  # The old monitor used only one file.
                result.check_returncode()
                target = Path(temp) / name
                target.write_text(result.stdout)
                files.append(target)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, files),
                        str(ROOT / 'scripts/tests/fixtures/MacOSInputMonitorFixture.swift'), '-o', str(binary)], check=True)
    if args.signing_identity:
        subprocess.run(['codesign', '--force', '--options', 'runtime,library', '--sign', args.signing_identity, str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    if args.build_only:
        print(binary)
    else:
        subprocess.run([str(binary), str(args.seconds), *(['--panel'] if args.panel else [])], timeout=args.seconds + 10, check=True)


if __name__ == '__main__':
    main()
