# Locked Use cold authorization latency

Investigation: 2026-10-31. This concerns normal manual screen unlock while Locked Use is installed, including when Broker is idle.

## Reproduced behavior

A manual-unlock trace took about 6.33 seconds from `system.login.screensaver` evaluation to success. About 6.24 seconds elapsed before `OCULockAuth:remote,privileged` was invoked. The mechanism itself returned Deny in about 11 ms with Broker idle, and the native fallback completed in about 73 ms.

The pre-invocation interval contains a Gatekeeper assessment of the staged authorization bundle. `syspolicyd` spent about three seconds on a ticket lookup that ended with `NSURLErrorDomain -1001`, followed by trust evaluation. Its scan finished immediately before the mechanism ran. The observed network path used a tunnel interface; the private destination was not available, so this does not establish which proxy rule or endpoint failed.

Immediate manual retries reused the same authorization host and completed in about 50 ms. The OS removed its staged bundle around 11 seconds after the final request. A slow retry also happened after only about two seconds of locking. Long lock duration is therefore not a required condition. A prior deep-idle wake can coincide with the issue, but is not its only trigger.

The existing `RemoteVerificationProbe.swift` reproduced this without locking the Mac:

| Request | Elapsed |
| --- | --- |
| Initial remote-right evaluation | 3175 ms |
| Immediate repeat | 8.5 ms |
| Another evaluation after an idle gap | 3403 ms |
| Immediate repeat | 10.1 ms |

Other cold requests ranged from roughly 0.3 to 3.2 seconds. Cold-start latency varies with security / network caches; a 20-second gap does not guarantee a network timeout. Actual `mechanismInvoked`, `brokerVerified`, `pluginClaim ... denied=1`, and `resultDelivered allowed=0` markers were observed. A denied API result by itself would not prove the plug-in loaded.

## Code and distribution findings

1. `LockedUseAuthorizationRules.planInstallation` prepends the remote branch to the existing native branches. Every manual unlock therefore enters the remote branch even when Broker is idle.
2. `RemotePlugin.m` starts its two-second IPC deadline **inside** `mechanismInvoke`. It cannot bound the OS's earlier staging, library loading, Gatekeeper, or trust evaluation. Reducing the Broker timeout cannot fix the observed pre-invocation delay.
3. The release workflow previously stapled only the outer App. The separately installed `OCULockAuth.bundle` had no stapled ticket (`stapler validate` returned 65). Stapling a scratch copy succeeded and added `Contents/CodeResources`; its code signature still verified.
4. The npm staging copies and tarballs were created before that outer-App notarization step and never refreshed. Thus the npm installation did not even receive the outer App's ticket.
5. Stapling a nested bundle under `Contents/Resources/LockedUse` changes the outer App's resource seal. In a scratch copy, deep strict verification failed after that operation and passed again after re-signing the outer App. Merely adding a child-stapling command after signing is incomplete.

The host also emitted a library-validation loading error before successfully invoking the mechanism. The bundle verified on disk and real mechanism markers followed; this message alone is not evidence that the final load failed.

## Repeatable diagnostic

Run from the repository, normally unlocked, with no Locked Use task in progress:

```bash
python3 scripts/measure-locked-use-auth-latency.py \
  --output .build/locked-use-latency/report.json
```

It compiles the existing probe into a temporary directory, evaluates only the already-installed remote right twice, waits 20 seconds, and repeats. Before each request the probe checks the console user, unlocked state, and the remote rule's expected non-shared privileged mechanism. It creates no authorization rules, credentials, leases, permits, synthesized input, or screensaver-right requests. Unexpected authorization results stop the run. The optional report contains normalized timings only.

Verify loading separately in unified logs; do not commit raw output:

```bash
log show --last 2m --style compact --info \
  --predicate 'subsystem == "dev.opencomputeruse.locked-use" AND category == "AuthorizationMechanism"'
```

## Prepared release correction and limits

`scripts/notarize-open-computer-use.sh` notarizes the installable payload, staples and validates its authorization bundle and Guardian App, re-signs the outer App while preserving signing metadata, then notarizes and staples that final App. The workflow subsequently uses `release-package.sh --skip-build` to refresh both npm and direct-download artifacts without rebuilding the native binaries. Simulated Apple-tool failures must stop this sequence before release packaging proceeds.

This repairs the observed ticket-distribution gaps. It does **not** prove every future cold load will avoid all network checks, nor that the manual-unlock delay is fixed end to end. Security revocation and other trust checks can still use the network. The installed components and screensaver policy were not changed. A full signed/notarized build, installer round trip, and cold/warm manual-unlock comparison remain required before claiming a user-visible fix. The installed 1.1.1 versus bundled 1.1.2 version difference alone was not established as the cause.

Apple's [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) specifies notarizing and stapling custom-installer payloads before notarizing their container, and explains offline ticket availability. See also [authorization plug-ins](https://developer.apple.com/documentation/security/extending-authorization-services-with-plug-ins) and [Gatekeeper diagnostics](https://developer.apple.com/forums/thread/706379).

## Release acceptance still required

The `locked-use-distribution-tests` workflow is an offline regression suite, not
another distribution channel. Its packaging test runs the repository's actual
staging, npm pack, direct-download packaging and manifest generation against tiny
prebuilt files. It checks all three npm aliases and the App ZIP for the outer App,
authorization bundle and Guardian ticket bytes. Apple-only tools are simulated;
passing this test does not establish that a ticket or signature is valid.

Before claiming the unlock latency is fixed, record these checks against the same
candidate commit and version:

1. Produce a real Developer ID build and complete both Apple notarization
   submissions. Confirm both statuses are Accepted. A manual release workflow or
   a build that skipped notarization is not evidence for this check; the current
   workflow only runs the notarization step on tag pushes with credentials.
2. Unpack each npm tarball and the direct-download App ZIP into separate temporary
   directories. For each extracted App, run `codesign --verify --deep --strict`
   and `xcrun stapler validate`. Also run `xcrun stapler validate` on both
   `Contents/Resources/LockedUse/OCULockAuth.bundle` and
   `Contents/Resources/LockedUse/OCU Guardian.app`. Verify the published manifest
   hashes refer to these final archives.
3. On a test Mac, capture the existing four-sample diagnostic before updating.
   Install the candidate using the documented disable / enable procedure; merely
   updating npm does not replace the system components. Confirm the installed
   version and validate the ticket on the installed authorization bundle at
   `/Library/Security/SecurityAgentPlugins/OCULockAuth.bundle`.
4. Repeat several four-sample runs under comparable network conditions. Correlate
   the normalized times with `mechanismInvoked` / `resultDelivered` and host-loading
   evidence. An idle gap alone does not prove a cold load, and an expected Deny
   alone does not prove that the mechanism ran.
5. Have the operator compare manual unlocks after an unlocked idle interval of
   30–60 seconds and immediate repeats; record wake-from-sleep trials separately.
   Compare time before mechanism entry, time inside the mechanism, native fallback,
   and total unlock time. Keep raw logs and machine identifiers out of the repository.

Do not clear OS trust caches, delete staged plug-ins, or change authentication
policy outside the documented installer to force a cold sample. If the candidate
still stalls before mechanism entry with validated installed tickets, investigate
remaining trust / revocation / network evaluation; reducing the in-plugin IPC
timeout cannot bound this earlier interval.
