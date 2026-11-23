# Locked Use orphaned recovery

The maintainer asked to prioritize #198 and reproduce it before fixing it.
After a Broker restart, a recovery record for a turn that never received
authorization could stay in relocking until reboot. Its owner, Guardian and
watchdog had exited, so no process remained to provide a session observation.

The Broker now retires a recovered lease only if it never granted the allow,
never observed an unlock for that lease, and the kernel confirms all recorded
processes have exited. The Broker persists the grant flag before sending any
allow. A fresh coordinator clears the old lease without inferring the console's
lock state. It preserves runtime settings and the installation policy's
acceptance decision. The existing persistence path removes the record.
Ordinary GUI requests still check the console session.

Before the fix, 600 timer polls of a synthetic record from #198 kept the
coordinator in relocking and left the recovery record pending. This regression
runs the same process-polling path as BrokerMain and injects exit evidence.
It never locks the real desktop or touches the installed service.

The corrected poll returns idle and no record. A new lease still requires a
matching locked session. Negative tests keep the fence if a recorded peer has
no exit evidence or authorization was previously granted. Already-released
recovery still waits for the existing manual-unlock observation and retiring
an ungranted record does not re-enable an invalidated installation.

Swift: 510 tests across four bundles, 14 skipped, zero failures. All 13
Locked Use recovery tests passed. Repository CI checks passed locally.
The OCULockService executable built successfully.
