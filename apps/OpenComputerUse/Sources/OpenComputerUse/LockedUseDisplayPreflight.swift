import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OpenComputerUseKit
import os

/// Bounded, caffeinate-equivalent display readiness for one locked-use episode.
///
/// The Guardian's shield coverage and the release-side lock-presentation evidence both
/// require `CGGetActiveDisplayList` to report at least one active display; a sleeping
/// display reports zero, so acquisitions issued into a dark display fail with
/// `activeDisplayCountUnavailable` and a relock that coincides with display sleep
/// latches `awaitingManualUnlock`. Nothing on the acquisition path previously ensured
/// the display was awake when the preparation deadline started counting.
///
/// This preflight reproduces what `caffeinate -u -d` was shown to fix operationally:
/// declare user activity (wakes the display), hold `PreventUserIdleDisplaySleep`
/// (prevents re-sleep) while the episode runs, and wait a bounded time for an active
/// display before `.begin` is sent. The broker's startup and Guardian preparation
/// budgets are unaffected because the wait happens entirely before the lease request.
/// Failing the wait is deliberately non-fatal: the existing Guardian checks still
/// decide admission, so this only improves readiness, never weakens it.
struct LockedUseDisplayPreflight {
    /// How long to wait for a woken display to become active before proceeding anyway.
    static let wakeTimeout: TimeInterval = 4
    static let pollInterval: TimeInterval = 0.25

    var activeDisplayCount: () -> Int = {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return 0 }
        return Int(count)
    }
    /// Replaces the external wake; injected so tests observe call order and retries.
    var declareUserActivity: () -> Void = {
        var identifier: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Open Computer Use locked session" as CFString,
                                             kIOPMUserActiveLocal, &identifier)
    }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var logger: Logger = Logger(subsystem: "dev.opencomputeruse.locked-use", category: "DisplayPreflight")

    /// Wakes a dark display and waits (bounded) for it to report active.
    /// Returns the terminal reason, purely for logging.
    @discardableResult
    func wakeForAcquisition() -> String {
        if activeDisplayCount() > 0 { return "alreadyAwake" }
        var attempts = 0
        let deadline = now() + Self.wakeTimeout
        while now() < deadline {
            attempts += 1
            declareUserActivity()
            sleep(Self.pollInterval)
            if activeDisplayCount() > 0 {
                logger.notice("displayWakeSucceeded attempts=\(attempts, privacy: .public)")
                return "woke"
            }
        }
        logger.warning("displayWakeTimedOut attempts=\(attempts, privacy: .public); proceeding, Guardian checks remain authoritative")
        return "wakeTimedOut"
    }
}

/// The `caffeinate -d` half: held from before `.begin` until the Broker's state
/// machine reports a terminal phase, so the relock's lock-presentation evidence can
/// form even when the task ended while the display was about to sleep. Carries its
/// own hard timeout so a crashed or wedged agent cannot hold the display forever
/// (powerd also releases assertions at process exit).
final class LockedUseDisplayHold {
    private static let safetyTimeout: TimeInterval = LockedUseStateMachine.maximumLease + 60
    private var identifier: IOPMAssertionID = 0
    private let mutex = NSLock()

    init?(logger: Logger) {
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionNameKey: "Open Computer Use locked session",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: Self.safetyTimeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &identifier) == kIOReturnSuccess else {
            logger.warning("displayHoldUnavailable; display may sleep mid-episode")
            return nil
        }
    }

    func release() {
        mutex.lock(); defer { mutex.unlock() }
        if identifier != 0 { _ = IOPMAssertionRelease(identifier); identifier = 0 }
    }

    deinit { release() }
}

/// Bounded wait for the release barrier to finish before `.begin` is sent again.
/// After a lease ends the Broker stays `idle` with `guardsReleased == false` until
/// both guards report lock-presentation evidence (which itself needs an active
/// display — the reason a wake also unblocks this path). Waiting is strictly
/// advisory: admission barriers are evaluated unchanged by the Broker afterwards.
func lockedUseAwaitReleasedGuards(
    status: () -> (phase: LockedUseStateMachine.Phase?, guardsReleased: Bool?)?,
    deadline: TimeInterval = 4,
    poll: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
) -> String {
    let stop = now() + deadline
    while true {
        guard let reply = status() else { return "statusUnavailable" }
        if reply.phase != .idle || reply.guardsReleased == true { return "ready" }
        if now() >= stop { return "releaseWaitTimedOut" }
        poll(0.2)
    }
}
