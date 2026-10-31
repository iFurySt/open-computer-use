# Locked Use cold authorization latency

## Goal

Reproduce intermittent manual-unlock latency without locking the desktop, identify the time spent before the authorization mechanism is invoked, and prepare a validated fix or a narrowly scoped diagnostic when a fix cannot yet be proved.

## Constraints

- Preserve the installed screensaver policy, Broker configuration, system plug-in, and OS-managed staged cache during diagnosis.
- Use only the existing remote right while normally unlocked. No credentials, new rights, leases, permits, synthesized input, or GUI-unlock requests.
- Distinguish signed code, notarization tickets, actual host loading, and completed GUI authentication.
- Record only normalized timing / fixed markers; keep raw machine logs out of version control.

## Evidence and work

- [x] Existing manual-unlock logs show about 6.24 seconds before mechanism invocation, about 11 ms inside the mechanism, and about 73 ms in native fallback.
- [x] Immediate subsequent unlocks reuse the same host and complete in about 50 ms. The OS removes the staged plug-in after the host becomes idle.
- [x] Repeat non-locking remote-right requests with an idle gap and correlate host / Gatekeeper timing. Observed approximately 3.17 s / 8.5 ms and 3.40 s / 10.1 ms pairs; later cold timings varied with security caches.
- [x] Inspect release notarization and ticket preservation. Installed authorization bundle lacks a stapled ticket; npm packages predate the outer-App notarization step. Version difference alone is not causal evidence.
- [x] Add repeatable diagnostics and focused regression coverage.
- [x] Prepare payload-first notarization, outer-App resealing, and complete artifact restaging. Scratch-copy tests verify child stapling changes the resource seal, which re-signing repairs.
- [x] Document established findings and verification limits in the cold-authorization reference.
- [x] Review follow-up: exercise real staging and direct-download scripts, assert all three ticket paths across every npm alias and App ZIP, and reject missing prebuilt runtimes. Expand workflow triggers and clarify its test-only role.
- [x] Turn the remaining real-build / installation / manual-unlock comparison into an explicit acceptance procedure in the cold-authorization reference.
- [ ] Run a real Developer ID / Apple notarization build and installer round trip, then compare cold/warm manual unlocks. Source correction is not yet a demonstrated end-to-end latency fix.

## Rollback

Diagnostic changes are ordinary source files. Do not install new components or change system authentication policy to test an unproved hypothesis. Any later real installation must use the signed installer and its existing conservative restore plan.
