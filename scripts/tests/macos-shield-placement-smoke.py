#!/usr/bin/env python3
"""Short real shields, no input filters/lock/authentication. Requires an unlocked Mac.

Compile production placement/coverage code, adding only passive observations.
--baseline-ref builds that Git version and expects the secondary-screen init offset.
--virtual-display temporarily creates a test-owned screen to the left, then removes it.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
GUARDIAN = "experiments/LockedUse/Sources/Guardian/"
KIT = "packages/OpenComputerUseKit/Sources/OpenComputerUseKit/"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    parser.add_argument("--virtual-display", action="store_true")
    args = parser.parse_args()

    def source(path):
        if args.baseline_ref:
            return subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    with tempfile.TemporaryDirectory(prefix="ocu-shield-placement-") as directory:
        temp = Path(directory)
        files = []
        for path in [KIT + "LockedUseShieldCoverage.swift", KIT + "LockedUseShieldStatus.swift",
                     GUARDIAN + "ShieldAppearance.swift", GUARDIAN + "DisplayShieldSurface.swift"]:
            code = source(path).replace("import OpenComputerUseKit\n", "")
            if path.endswith("DisplayShieldSurface.swift"):
                for anchor, stage in [("window.animationBehavior = .none", "initialized"),
                                      ("window.setFrame(frame, display: true)", "setFrame"),
                                      ("window.displayIfNeeded()", "displayed")]:
                    # Restrict the displayIfNeeded match to the coverDisplays body.
                    start = code.index("func coverDisplays(")
                    index = code.index(anchor, start)
                    observation = f'PlacementEvidence.record(window, screen: screen, stage: "{stage}")'
                    if stage == "initialized":
                        code = code[:index] + observation + "\n            " + code[index:]
                    else:
                        index += len(anchor)
                        code = code[:index] + "\n            " + observation + code[index:]
            target = temp / Path(path).name
            target.write_text(code)
            files.append(str(target))

        shim = ROOT / "packages/OpenComputerUseVirtualDisplayShim"
        obj = temp / "shim.o"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-c", str(shim / "OpenComputerUseVirtualDisplayShim.m"),
                        "-I", str(shim / "include"), "-o", str(obj)], check=True)
        binary = temp / "ShieldPlacementFixture"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", *files,
                        str(ROOT / "scripts/tests/fixtures/MacOSShieldPlacementFixture.swift"), str(obj),
                        "-import-objc-header", str(shim / "include/OpenComputerUseVirtualDisplayShim.h"),
                        "-o", str(binary)], check=True)
        def inventory():
            return json.loads(subprocess.check_output([str(binary), "--inventory"], text=True, timeout=5))

        original_displays = inventory()
        run = subprocess.run([str(binary), *(["--virtual-display"] if args.virtual_display else [])],
                             capture_output=True, text=True, timeout=30)
        print(run.stdout, end="")
        if run.stderr:
            print(run.stderr, end="")
        deadline = time.monotonic() + 5
        while inventory() != original_displays:
            assert time.monotonic() < deadline, "Display layout did not return to its original state"
            time.sleep(0.1)
        assert run.returncode == 0, "Real shield coverage failed"
        result = json.loads(run.stdout)
        assert not result["coverageFailures"]
        initialized = [s for s in result["samples"] if s["stage"] == "initialized"]
        assert initialized and all(s["aligned"] for s in result["samples"] if s["stage"] != "initialized")
        if args.baseline_ref:
            assert any(not s["aligned"] for s in initialized), "Baseline did not reproduce the init offset"
        else:
            assert all(s["aligned"] for s in initialized), "New shields must start at the intended frame"
        print("PASS: initialization observed; production WindowServer coverage stable; test displays removed.")


if __name__ == "__main__":
    main()
