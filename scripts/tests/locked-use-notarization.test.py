"""Run the real release orchestration against simulated Apple tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "notarize-open-computer-use.sh"
MOCK_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = pathlib.Path(os.environ['MOCK_STATE'])
state = json.loads(state_path.read_text())
state['calls'].append([name] + args)
def finish(code=0):
    state_path.write_text(json.dumps(state))
    sys.exit(code)
if name == 'ditto':
    pathlib.Path(args[-1]).touch()
elif name == 'codesign':
    if '--force' in args:
        if os.environ.get('MOCK_FAIL') == 'sign': finish(1)
        state['sealed'] = True
    elif not state['sealed']: finish(1)
elif name == 'xcrun':
    if args[:2] == ['notarytool', 'submit']:
        stage = 'payload' if args[2].endswith('payload.zip') else 'app'
        if stage == 'app' and not (state['sealed'] and state['tickets'] == 2): finish(1)
        status = 'Invalid' if os.environ.get('MOCK_FAIL') == stage else 'Accepted'
        print(json.dumps({'status': status, 'id': 'test-submission'}))
    elif args[:2] == ['stapler', 'staple']:
        if os.environ.get('MOCK_FAIL') == 'staple': finish(1)
        target = pathlib.Path(args[2]) / 'Contents' / 'CodeResources'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text('ticket')
        if 'LockedUse' in args[2]:
            state['tickets'] += 1
            state['sealed'] = False
    elif args[:2] == ['stapler', 'validate']:
        if not (pathlib.Path(args[2]) / 'Contents' / 'CodeResources').is_file(): finish(1)
    else: finish(1)
finish()
'''


class NotarizationTests(unittest.TestCase):
    def execute(self, failure=None):
        temporary = tempfile.TemporaryDirectory(prefix="ocu-notary-test-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copy(SCRIPT, scripts / SCRIPT.name)
        (scripts / "locked-use-build-common.sh").write_text('locked_use_sign() { codesign "$@"; }\n')
        verifier = scripts / "verify-locked-use-bundle.sh"
        verifier.write_text('#!/bin/bash\ncodesign --verify --deep --strict "$1"\n')
        verifier.chmod(0o755)
        commands = root / "bin"
        commands.mkdir()
        for name in ["xcrun", "ditto", "codesign"]:
            tool = commands / name
            tool.write_text(MOCK_TOOL)
            tool.chmod(0o755)
        app = root / "Example App.app"
        (app / "Contents/Resources/LockedUse").mkdir(parents=True)
        state_path = root / "state.json"
        state_path.write_text(json.dumps(dict(calls=[], sealed=True, tickets=0)))
        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           MOCK_STATE=str(state_path), OPEN_COMPUTER_USE_CODESIGN_IDENTITY="Developer ID Example",
                           MOCK_FAIL=failure or "")
        result = subprocess.run(["bash", str(scripts / SCRIPT.name), str(app), "--keychain-profile", "test"],
                                env=environment, capture_output=True, text=True, timeout=15)
        return result, json.loads(state_path.read_text()), app

    def testStaplesChildrenThenResealsParentBeforeFinalSubmission(self):
        result, state, app = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = state["calls"]
        submits = [i for i, c in enumerate(calls) if c[:3] == ["xcrun", "notarytool", "submit"]]
        staples = [i for i, c in enumerate(calls) if c[:3] == ["xcrun", "stapler", "staple"]]
        signing = next(i for i, c in enumerate(calls) if c[:2] == ["codesign", "--force"])
        self.assertEqual(len(submits), 2)
        self.assertEqual(len(staples), 3)
        self.assertLess(submits[0], staples[0])
        self.assertLess(staples[1], signing)
        self.assertLess(signing, submits[1])
        self.assertLess(submits[1], staples[2])
        for target in [app, app / "Contents/Resources/LockedUse/OCULockAuth.bundle",
                       app / "Contents/Resources/LockedUse/OCU Guardian.app"]:
            self.assertTrue((target / "Contents/CodeResources").is_file())
        self.assertTrue(state["sealed"])

    def testFailedPayloadNotarizationNeverStaplesOrResigns(self):
        result, state, _ = self.execute("payload")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["tickets"], 0)
        self.assertFalse(any(c[:2] == ["codesign", "--force"] for c in state["calls"]))

    def testFailureStopsBeforeFinalAppTicket(self):
        for failure in ["staple", "sign", "app"]:
            with self.subTest(failure=failure):
                result, _, app = self.execute(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((app / "Contents/CodeResources").exists())


if __name__ == "__main__":
    unittest.main()
