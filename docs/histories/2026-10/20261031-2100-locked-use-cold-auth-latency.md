## [2026-10-31 21:00] | Task: Reproduce Locked Use cold authorization latency

### Execution Context

- Agent ID: `/root`
- Base Model: GPT-6
- Runtime: Codex desktop, local macOS

### User Query

Investigate intermittent slow manual unlock in open-computer-use, identify the faulty path, and obtain a repeatable reproduction suitable for fixing it.

### Changes Overview

- Reproduced cold/warm authorization latency with the existing remote right while normally unlocked. Initial and idle-separated requests reached roughly 3.2–3.4 seconds; immediate repeats were roughly 9–12 ms. Cold timings vary with OS trust / network caches.
- Added a reusable four-sample diagnostic and hardened the existing probe's installed-rule preflight. No screensaver request, credentials, system policy mutation, lease creation, or synthesized input is involved.
- Located the delay before mechanism invocation, including a three-second Gatekeeper ticket-lookup timeout. Broker IPC itself returned promptly in idle state.
- Added payload-first notarization and child ticket validation, preserved-metadata outer-App re-signing, final-App notarization, and npm/direct-download restaging without native rebuilds.
- Added failure-path orchestration tests and an actual npm tarball test verifying the refreshed child-ticket file survives packaging. Added the focused Python tests to the existing CI script and a dedicated PR/main workflow requiring no Apple credentials.
- Documented evidence, reproduction, source corrections, and remaining real-build / installation validation.

### Design Intent

The plugin's internal timeout begins after OS loading, so changing it cannot bound this delay. Separately installed bundles need their own stapled tickets. Since these bundles are sealed as outer-App resources, child stapling must precede the final outer signature and notarization. npm must copy that final App rather than retain its earlier staging copy.

### Validation

- Non-locking probe reproduced slow/fast pairs and real mechanism / Deny markers in unified logs.
- Real scratch bundle: stapling succeeded and standalone signature verification passed. Outer-App strict verification failed after child stapling and passed after local scratch re-signing.
- Focused latency, notarization-failure and real npm repacking tests, shared signing helper regression, shell syntax, document skeleton and diff whitespace checks.
- The default Homebrew Node executable could not start because of a missing shared library. Packaging validation used an existing working Node installation without modifying the system runtime.
- Installed components and authentication policy remain unchanged. No real notarization submission, release publication, or installation of this correction was performed. End-to-end unlock improvement remains unverified.

### Files Modified

- `experiments/LockedUse/Sources/RemoteVerificationProbe.swift`
- `scripts/measure-locked-use-auth-latency.py`
- `scripts/notarize-open-computer-use.sh`
- `scripts/release-package.sh`
- `scripts/ci.sh`
- `.github/workflows/release.yml`
- `.github/workflows/locked-use-distribution.yml`
- `scripts/tests/locked-use-auth-latency.test.py`
- `scripts/tests/locked-use-notarization.test.py`
- `scripts/tests/locked-use-release-packaging.test.py`
- `docs/references/macos-locked-use-cold-auth-latency.md` and linked release / diagnostic guides
