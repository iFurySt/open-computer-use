#!/usr/bin/env python3
"""Repeat the existing remote-right probe without locking or modifying policy."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def measure(probe, idle_seconds, run=subprocess.run, sleep=time.sleep):
    samples = []
    for label, delay in [("initial", 0), ("immediate", 0),
                         ("afterIdle", idle_seconds), ("immediateAfterIdle", 0)]:
        if delay:
            sleep(delay)
        result = run([str(probe)], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError("Remote probe refused or failed; no further requests made.")
        record = json.loads(result.stdout)
        elapsed = record.get("elapsedSeconds")
        if (record.get("event") != "remoteVerificationProbe"
                or record.get("status") != -60005
                or record.get("expectedDenied") is not True
                or record.get("sessionLockRequested") is not False
                or type(elapsed) not in (int, float) or not 0 <= elapsed < 30):
            raise RuntimeError("Unexpected remote authorization result; stopping.")
        sample = {"sample": label, "idleSeconds": delay,
                  "elapsedMilliseconds": round(elapsed * 1000, 3), "expectedDenied": True}
        samples.append(sample)
        print(json.dumps(sample), flush=True)
    return {"schemaVersion": 1, "sessionLockRequested": False,
            "authenticationPolicyChanged": False, "samples": samples,
            "pluginLoading": "Confirm mechanismInvoked/resultDelivered in unified logs; denial alone is not loading evidence."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--idle-seconds", type=float, default=20,
                        help="Idle gap before the second pair (15–60 seconds; default 20).")
    parser.add_argument("--output", type=Path,
                        help="Optional normalized JSON report; raw OS logs are never saved.")
    args = parser.parse_args()
    if sys.platform != "darwin" or not 15 <= args.idle_seconds <= 60:
        parser.error("Requires macOS and an idle gap between 15 and 60 seconds.")
    source = Path(__file__).resolve().parents[1] / "experiments/LockedUse/Sources/RemoteVerificationProbe.swift"
    try:
        with tempfile.TemporaryDirectory(prefix="ocu-auth-latency-") as directory:
            probe = Path(directory) / "remote-verification-probe"
            subprocess.run(["xcrun", "swiftc", "-framework", "Security", "-framework", "CoreGraphics",
                            str(source), "-o", str(probe)], check=True, timeout=60)
            report = measure(probe, args.idle_seconds)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
