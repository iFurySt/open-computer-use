"""Execute release workflow shell blocks without credentials or external services."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()
APP_STEP = "Notarize installable payload and Open Computer Use app"
DMG_STEP = "Notarize Cursor Motion DMG"
NOTARY_KEYS = (
    "APPLE_NOTARY_API_KEY_P8_BASE64", "APPLE_NOTARY_KEY_ID",
    "APPLE_NOTARY_ISSUER_ID", "APPLE_DEVELOPER_TEAM_ID",
)
SIGNING_KEYS = (
    "OPEN_COMPUTER_USE_CODESIGN_P12_BASE64", "OPEN_COMPUTER_USE_CODESIGN_P12_PASSWORD",
)


def step(name):
    # Read the workflow's fixed indentation, not a copy of its shell logic.
    match = re.search(r"^      - name: " + re.escape(name) +
                      r"\n(.*?)(?=^      - name:|^  [\w-]+:|\Z)", WORKFLOW, re.M | re.S)
    if not match:
        raise AssertionError(f"Missing workflow step: {name}")
    return match.group(1)


MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as out:
    out.write(json.dumps([name] + args) + '\n')
failure = os.environ.get('FAIL', '')
if name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        if failure == 'submit': sys.exit(1)
        print(json.dumps({'status': 'Invalid' if failure == 'rejected' else 'Accepted'}))
    elif args[:2] == ['stapler', failure]:
        sys.exit(1)
elif name == 'notarize-open-computer-use.sh' and failure == 'app':
    sys.exit(1)
elif name == 'release-package.sh' and failure == 'repack':
    sys.exit(1)
elif name == 'security':
    # Tests must never reach the host keychain (even with mock credentials).
    sys.exit(99)
'''


class ReleasePolicyTests(unittest.TestCase):
    def execute(self, name, overrides=None):
        with tempfile.TemporaryDirectory(prefix="ocu-release-policy-") as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "scripts").mkdir()
            for path in ("bin/xcrun", "bin/security", "bin/codesign",
                         "scripts/notarize-open-computer-use.sh", "scripts/release-package.sh"):
                target = root / path
                if path.startswith("scripts/"):
                    # Workflow invokes the app script via bash explicitly.
                    target.write_text('#!/bin/bash\nexec python3 "$0.mock" "$@"\n')
                    target.with_name(target.name + ".mock").write_text(
                        MOCK_TOOL.replace("pathlib.Path(sys.argv[0]).name", "pathlib.Path(sys.argv[0]).name.removesuffix('.mock')"))
                else:
                    target.write_text(MOCK_TOOL)
                target.chmod(0o755)
            environment = {
                "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"],
                "RUNNER_TEMP": str(root), "GITHUB_ENV": str(root / "github-env"),
                "CALLS": str(root / "calls"), "RELEASE_TAG": "v0.0.0",
                "OPEN_COMPUTER_USE_CODESIGN_MODE": "identity",
                "CURSOR_MOTION_CODESIGN_MODE": "identity",
                **{key: "test-value" for key in NOTARY_KEYS + SIGNING_KEYS},
            }
            environment["APPLE_NOTARY_API_KEY_P8_BASE64"] = base64.b64encode(b"fake-key").decode()
            environment.update(overrides or {})
            block = step(name)
            shell = textwrap.dedent(block.split("        run: |\n", 1)[1])
            result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", shell],
                                    cwd=root, env=environment, capture_output=True, text=True, timeout=15)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()] if (root / "calls").exists() else []
            return result, calls

    def testEveryPublishEntryRunsNotarization(self):
        condition = "        if: ${{ github.event_name == 'push' || inputs.publish_to_npm }}"
        for name in (APP_STEP, "Publish packages to npm"):
            self.assertIn(condition, step(name).splitlines())
            self.assertNotIn("continue-on-error:", step(name))
        self.assertLess(WORKFLOW.index("- name: " + APP_STEP), WORKFLOW.index("- name: Publish packages to npm"))
        self.assertRegex(WORKFLOW, r"publish-github-release:\n    needs:\n      - package-npm\n      - release-cursor-motion-dmg")

    def testMissingSigningCredentialsStopBeforeKeychainAccess(self):
        for name in ("Prepare Open Computer Use signing config", "Prepare Cursor Motion signing config"):
            for key in SIGNING_KEYS:
                with self.subTest(step=name, missing=key):
                    result, calls = self.execute(name, {key: ""})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("credentials are required", result.stderr)
                    self.assertEqual(calls, [])

    def testEveryMissingNotaryCredentialBlocksBothArtifacts(self):
        for name in (APP_STEP, DMG_STEP):
            for key in NOTARY_KEYS:
                with self.subTest(step=name, missing=key):
                    result, calls = self.execute(name, {key: ""})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("credentials are required", result.stderr)
                    self.assertEqual(calls, [])

    def testAdhocArtifactsCannotPassNotarizationStep(self):
        for name, key in ((APP_STEP, "OPEN_COMPUTER_USE_CODESIGN_MODE"),
                          (DMG_STEP, "CURSOR_MOTION_CODESIGN_MODE")):
            with self.subTest(step=name):
                result, calls = self.execute(name, {key: "adhoc"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def testAppNotarizationFailureStopsBeforeRepacking(self):
        result, calls = self.execute(APP_STEP, {"FAIL": "app"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c[0] for c in calls], ["notarize-open-computer-use.sh"])

    def testAppSuccessRepacksAndRepackFailureIsFatal(self):
        for failure in ("", "repack"):
            with self.subTest(failure=failure):
                result, calls = self.execute(APP_STEP, {"FAIL": failure})
                self.assertEqual(result.returncode == 0, not failure, result.stderr)
                self.assertEqual([c[0] for c in calls], ["notarize-open-computer-use.sh", "release-package.sh"])
                self.assertEqual(calls[-1][1:], ["--skip-build"])

    def testDmgRequiresAcceptedSubmissionAndValidatedTicket(self):
        for failure, count in (("submit", 1), ("rejected", 1), ("staple", 2), ("validate", 3), ("", 3)):
            with self.subTest(failure=failure):
                result, calls = self.execute(DMG_STEP, {"FAIL": failure})
                self.assertEqual(result.returncode == 0, not failure, result.stderr)
                self.assertEqual(len(calls), count)
                if not failure:
                    self.assertEqual([c[1:3] for c in calls],
                                     [["notarytool", "submit"], ["stapler", "staple"], ["stapler", "validate"]])


if __name__ == "__main__":
    unittest.main()
