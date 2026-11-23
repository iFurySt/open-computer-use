# Locked Use recovery after an interrupted turn

Issue #198 reports a same-boot Broker recovery record that leaves GUI tools stuck
in relocking even after all recorded processes have exited. Reproduce with the
production coordinator polling path and fake process checks. Keep validation
and permit issuance unchanged. Retire only recovery from a turn that never
granted authorization, with positive exit evidence for every recorded process.

- [x] Reproduce 600 unsuccessful polls on the original logic.
- [x] Cover missing exit evidence, granted and already-released records, and an invalidated installation.
- [x] Run Swift and repository tests and record limits. Verification
  must not change the installed service or lock the desktop.
