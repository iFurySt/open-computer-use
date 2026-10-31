"""Real staging/archive scripts with tiny prebuilt native fixtures.

Only macOS inspection/archive tools are simulated. This checks bytes, not
signature validity, notarization validity, or the system installation transaction.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[2]
APP = "Open Computer Use.app"
PACKAGES = ("open-computer-use", "open-computer-use-mcp", "open-codex-computer-use-mcp")
TICKETS = (
    "Contents/CodeResources",
    "Contents/Resources/LockedUse/OCULockAuth.bundle/Contents/CodeResources",
    "Contents/Resources/LockedUse/OCU Guardian.app/Contents/CodeResources",
)
APPLE_TOOL = r'''#!/usr/bin/env python3
import pathlib, sys, zipfile
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'lipo':
    if args[0] == '-archs': print('arm64 x86_64')
elif name == 'codesign':
    if '-dv' in args: print('TeamIdentifier=TESTTEAM01', file=sys.stderr)
elif name == 'ditto':
    source, target = map(pathlib.Path, args[-2:])
    with zipfile.ZipFile(target, 'w') as archive:
        for entry in sorted(source.rglob('*')):
            if entry.is_file(): archive.write(entry, entry.relative_to(source.parent))
else:
    sys.exit('Unexpected mock tool')
'''


@unittest.skipUnless(all(shutil.which(tool) for tool in ("node", "npm", "zip", "unzip", "shasum")),
                     "requires Node, npm, zip, unzip and shasum")
class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ocu-repack-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for pattern in ("*.sh", "*.mjs"):
            for source in (REPO / "scripts").glob(pattern):
                shutil.copy2(source, scripts / source.name)
        for directory in ("scripts/npm", "scripts/node-repl", "plugins/open-computer-use",
                          "skills/open-computer-use", ".agents/plugins"):
            shutil.copytree(REPO / directory, self.root / directory)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(REPO / name, self.root / name)
        # Fail any accidental rebuild even on a developer Mac with Swift.
        for name in ("app", "linux", "windows"):
            (scripts / f"build-open-computer-use-{name}.sh").write_text(
                '#!/bin/bash\necho "Unexpected native rebuild" >&2\nexit 99\n')
        self.version = json.loads((self.root / "plugins/open-computer-use/.codex-plugin/plugin.json").read_text())["version"]
        self.app = self.root / "dist" / APP
        for relative in ("Contents/MacOS/OpenComputerUse",
                         "Contents/Resources/LockedUse/OCULockService",
                         "Contents/Resources/LockedUse/OCULockInstaller",
                         "Contents/Resources/LockedUse/OCU Guardian.app/Contents/MacOS/OCUGuardian",
                         "Contents/Resources/LockedUse/OCULockAuth.bundle/Contents/MacOS/OCULockAuth"):
            binary = self.app / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"native-fixture")
            binary.chmod(0o755)
        for platform, binary_name in (("linux", "open-computer-use"), ("windows", "open-computer-use.exe")):
            for arch in ("arm64", "amd64"):
                binary = self.root / "dist" / platform / arch / binary_name
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(b"native-fixture")
        for ticket in TICKETS:
            (self.app / ticket).write_bytes(b"new-ticket:" + ticket.encode())
        for package in PACKAGES:
            stale = self.root / "dist/release/npm-staging" / package / "dist" / APP
            stale.mkdir(parents=True)
            (stale / "stale").touch()
        commands = self.root / "bin"
        commands.mkdir()
        for name in ("codesign", "lipo", "ditto"):
            tool = commands / name
            tool.write_text(APPLE_TOOL)
            tool.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                                GITHUB_SHA="test-sha")

    def release(self):
        return subprocess.run(["bash", str(self.root / "scripts/release-package.sh"), "--skip-build"],
                              cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=60)

    def testRealStagingPreservesAllTicketsInEveryReleaseArchive(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.root / "dist/release"
        for package in PACKAGES:
            staged = release / "npm-staging" / package / "dist" / APP
            self.assertFalse((staged / "stale").exists())
            with tarfile.open(release / "npm" / f"{package}-{self.version}.tgz") as archive:
                for ticket in TICKETS:
                    expected = (self.app / ticket).read_bytes()
                    self.assertEqual((staged / ticket).read_bytes(), expected)
                    self.assertEqual(archive.extractfile(f"package/dist/{APP}/{ticket}").read(), expected)
        with zipfile.ZipFile(release / "github" / f"Open-Computer-Use-{self.version}-macOS-universal.app.zip") as archive:
            for ticket in TICKETS:
                self.assertEqual(archive.read(f"{APP}/{ticket}"), (self.app / ticket).read_bytes())
        manifest = json.loads((release / "release-manifest.json").read_text())
        self.assertEqual(manifest["distribution"]["package_count"], len(PACKAGES))
        for artifact in manifest["artifacts"]:
            self.assertEqual(artifact["size_bytes"], (release / "npm" / artifact["name"]).stat().st_size)
        assets = json.loads((release / "github/release-assets-manifest.json").read_text())
        for artifact in assets["artifacts"]:
            data = (release / "github" / artifact["name"]).read_bytes()
            self.assertEqual(artifact["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(artifact["size_bytes"], len(data))

    def testMissingPrebuiltRuntimeStopsPackaging(self):
        (self.root / "dist/linux/arm64/open-computer-use").unlink()
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing artifact", result.stderr)
        self.assertEqual(list((self.root / "dist/release/npm").glob("*.tgz")), [])
        self.assertFalse((self.root / "dist/release/github").exists())


if __name__ == "__main__":
    unittest.main()
