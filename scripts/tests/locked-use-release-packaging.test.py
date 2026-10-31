"""Repacking must ship the post-notarization copy, including child tickets."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


class ReleasePackagingTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("node") and shutil.which("npm"), "requires Node and npm")
    def testSkipBuildRestagesTicketedPayloadIntoNpmTarball(self):
        with tempfile.TemporaryDirectory(prefix="ocu-repack-test-") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            (scripts / "npm").mkdir(parents=True)
            shutil.copy(Path(__file__).resolve().parents[1] / "release-package.sh", scripts)
            # Stand in for native builds with one tiny app; use actual Node
            # copying and npm packing to check the on-disk ticket survives.
            (scripts / "npm/build-packages.mjs").write_text('''
import {cpSync, mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
if (!process.argv.includes('--skip-build')) throw Error('unexpected native rebuild');
const stage = process.argv[process.argv.indexOf('--out-dir') + 1];
const pkg = path.join(stage, 'test-package');
mkdirSync(path.join(pkg, 'dist'), {recursive:true});
writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({name:'ocu-ticket-test',version:'1.0.0'}));
cpSync('dist/Example.app', path.join(pkg, 'dist/Example.app'), {recursive:true});
''')
            assets = scripts / "package-github-release-assets.sh"
            assets.write_text('#!/bin/bash\nmkdir -p dist/release/github\n')
            assets.chmod(0o755)
            ticket = Path("Contents/Resources/LockedUse/OCULockAuth.bundle/Contents/CodeResources")
            source = root / "dist/Example.app" / ticket
            source.parent.mkdir(parents=True)
            source.write_bytes(b"new-stapled-ticket")
            # This is the stale package that the release command must replace.
            stale = root / "dist/release/npm-staging/old"
            stale.mkdir(parents=True)
            (stale / "stale").touch()
            result = subprocess.run(["bash", str(scripts / "release-package.sh"), "--skip-build"],
                                    cwd=root, env=dict(os.environ, GITHUB_SHA="test-sha"),
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(stale.exists())
            archive = root / "dist/release/npm/ocu-ticket-test-1.0.0.tgz"
            with tarfile.open(archive) as packaged:
                content = packaged.extractfile("package/dist/Example.app/" + str(ticket)).read()
            self.assertEqual(content, b"new-stapled-ticket")
            manifest = json.loads((root / "dist/release/release-manifest.json").read_text())
            self.assertEqual(manifest["distribution"]["package_count"], 1)
            self.assertEqual(manifest["artifacts"][0]["size_bytes"], archive.stat().st_size)


if __name__ == "__main__":
    unittest.main()
