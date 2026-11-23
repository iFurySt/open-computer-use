# Locked Use: release an abandoned ungranted relock

Issue #198. An interrupted locked turn left `lease-recovery.json` on disk. Its
owner, Guardian and watchdog processes had all exited. On every start the Broker
reloaded the record and stayed in `relocking` for the rest of the boot. Unscoped
GUI calls were refused with "Locked Use belongs to another connection" even
while the session was unlocked.

`ownerProcessExited()` confirmed quiescence but called `observe` only when an
`observedSession` existed. After recovery, only a Guardian report, an owner
recovery hello or a watchdog report sets that value. When all three processes
are gone, nothing sets it, so the phase never left `relocking`.

The fix is narrow. If no unlock was ever granted (`everGranted == false`), the
Guardian process is gone and the agent has drained, the coordinator moves the
recovered lease to `awaitingManualUnlock` and releases guards. OCU never
unlocked the desktop in this case, so nothing is left to relock. A new lease is
still refused until a normal manual unlock. Granted leases keep the existing
behaviour and still need a real relock observation.

Tests: `LockedUseStaleRecoveryTests` covers the ungranted case (fails on
`79c552a` with `relocking`, passes with the fix) and two granted cases that must
stay `relocking`. All 156 `LockedUse` tests pass locally on Apple Silicon.

Not verified: a real interrupted locked turn on a build with this change. The
local reproduction used the coordinator API with the recovered record's shape.
