"""Latency runner contracts; no real authorization, desktop or system changes."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("latency", Path(__file__).resolve().parents[1] / "measure-locked-use-auth-latency.py")
latency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latency)


class LatencyTests(unittest.TestCase):
    def result(self, elapsed=0.01, **changes):
        record = dict(event="remoteVerificationProbe", status=-60005, expectedDenied=True,
                      sessionLockRequested=False, elapsedSeconds=elapsed)
        record.update(changes)
        return SimpleNamespace(returncode=0, stdout=json.dumps(record))

    def measure(self, run, sleep=None):
        with contextlib.redirect_stdout(io.StringIO()):
            return latency.measure(Path("/diagnostic/probe"), 20, run, sleep or Mock())

    def testIdleGapSeparatesTwoPairsAndReportOnlyKeepsNormalizedFields(self):
        run = Mock(side_effect=[self.result(3.2, private="discard"), self.result(.009),
                                self.result(3.4), self.result(.010)])
        sleep = Mock()
        report = self.measure(run, sleep)
        sleep.assert_called_once_with(20)
        self.assertEqual([s["elapsedMilliseconds"] for s in report["samples"]], [3200, 9, 3400, 10])
        self.assertEqual(run.call_count, 4)
        for call in run.call_args_list:
            self.assertEqual(call.args[0], ["/diagnostic/probe"])
        self.assertNotIn("private", json.dumps(report))
        self.assertFalse(report["sessionLockRequested"])
        self.assertIn("denial alone", report["pluginLoading"])

    def testRefusalStopsBeforeNextRequestOrIdle(self):
        run = Mock(return_value=SimpleNamespace(returncode=2, stdout=""))
        sleep = Mock()
        with self.assertRaises(RuntimeError):
            self.measure(run, sleep)
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()

    def testUnexpectedAllowOrLockRequestStopsImmediately(self):
        for changes in [dict(status=0), dict(expectedDenied=False), dict(sessionLockRequested=True),
                        dict(event="other"), dict(elapsedSeconds=float("nan")), dict(elapsedSeconds=True)]:
            run = Mock(return_value=self.result(**changes))
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.measure(run)
            self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
