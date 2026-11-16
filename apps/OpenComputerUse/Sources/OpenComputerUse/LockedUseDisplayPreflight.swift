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
    var declareUserActivity: (inout IOPMAssertionID) -> Void = { identifier in
        _ = IOPMAssertionDeclareUserActivity("Open Computer Use locked session" as CFString,
                                             kIOPMUserActiveLocal, &identifier)
    }
    var releaseUserActivity: (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var logger: Logger = Logger(subsystem: "dev.opencomputeruse.locked-use", category: "DisplayPreflight")

    /// Wakes a dark display and waits (bounded) for it to report active.
    /// Returns the terminal reason, purely for logging.
    @discardableResult
    func wakeForAcquisition() -> String {
        if activeDisplayCount() > 0 { return "alreadyAwake" }
        // The API can replace this ID on a retry. Reuse its latest value and
        // release it even when the display never becomes active.
        var activity: IOPMAssertionID = 0
        defer { if activity != 0 { releaseUserActivity(activity) } }
        var attempts = 0
        let deadline = now() + Self.wakeTimeout
        while now() < deadline {
            attempts += 1
            declareUserActivity(&activity)
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

/// One episode's prevent-idle-sleep assertion. Ownership starts before wake,
/// transfers to the connection only after admission, and ends after BOTH guards
/// have released. A terminal Broker phase alone is not release evidence.
final class LockedUseDisplayHold: @unchecked Sendable {
    static let releaseGrace: TimeInterval = 60
    private static let safetyTimeout: TimeInterval = LockedUseStateMachine.maximumLease + releaseGrace
    private var releaseAssertion: (() -> Void)?
    private let mutex = NSLock()

    convenience init?(logger: Logger) {
        var identifier: IOPMAssertionID = 0
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
        self.init(releaseAssertion: { _ = IOPMAssertionRelease(identifier) })
    }

    /// Also lets regression tests count releases without creating power assertions.
    init(releaseAssertion: @escaping () -> Void) {
        self.releaseAssertion = releaseAssertion
    }

    func release() {
        mutex.lock(); defer { mutex.unlock() }
        releaseAssertion?()
        releaseAssertion = nil
    }

    /// Runs off the request/polling queue after a terminal reply. Unavailable
    /// status is not evidence of release; retry within the cleanup grace period.
    /// The native assertion also expires independently if this worker wedges.
    @discardableResult
    func waitForRelease(
        status: () -> Bool?,
        timeout: TimeInterval = LockedUseDisplayHold.releaseGrace,
        poll: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> String {
        defer { release() }
        let deadline = now() + timeout
        while now() < deadline {
            if status() == true { return "guardsReleased" }
            let remaining = deadline - now()
            if remaining > 0 { poll(min(0.2, remaining)) }
        }
        return "displayReleaseWaitTimedOut"
    }

    deinit { release() }
}

/// Reuse one authenticated observer while polling instead of paying the cold
/// handshake cost on every sample. A failed request closes it before retrying.
final class LockedUseDisplayReleaseObserver {
    private var connection: LockedUseIPCClient?

    func status() -> (phase: LockedUseStateMachine.Phase?, guardsReleased: Bool?)? {
        do {
            if connection == nil {
                connection = try LockedUseIPCClient(endpoint: .observer,
                    brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
            }
            guard let reply = try connection?.request(.init(operation: .status, session: .current())) else { return nil }
            return (reply.phase, reply.guardsReleased)
        } catch {
            connection?.close(); connection = nil
            return nil
        }
    }
}

/// Bounded polling for the release barrier to finish before `.begin` is sent again.
/// After a lease ends the Broker stays `idle` with `guardsReleased == false` until
/// both guards report lock-presentation evidence (which itself needs an active
/// display — the reason a wake also unblocks this path). Waiting is strictly
/// advisory: admission barriers are evaluated unchanged by the Broker afterwards.
/// The polling budget excludes an in-flight status call, which has its own IPC
/// deadlines (including the first reply's cold-authentication budget).
func lockedUseAwaitReleasedGuards(
    status: () -> (phase: LockedUseStateMachine.Phase?, guardsReleased: Bool?)?,
    deadline: TimeInterval = 4,
    poll: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
) -> String {
    let stop = now() + deadline
    while now() < stop {
        guard let reply = status() else { return "statusUnavailable" }
        if reply.phase != .idle || reply.guardsReleased == true { return "ready" }
        let remaining = stop - now()
        if remaining <= 0 { return "releaseWaitTimedOut" }
        poll(min(0.2, remaining))
    }
    return "releaseWaitTimedOut"
}
