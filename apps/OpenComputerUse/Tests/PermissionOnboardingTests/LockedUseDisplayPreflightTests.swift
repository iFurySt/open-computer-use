import XCTest
import os
import IOKit.pwr_mgt
@testable import OpenComputerUse
import OpenComputerUseKit

/// Display readiness is injected everywhere, so these tests exercise the full decision
/// logic (retry counts, call order, bounded waits) without touching powerd or CoreGraphics.
final class LockedUseDisplayPreflightTests: XCTestCase {
    private func makePreflight(activeCounts: [Int], clockStep: TimeInterval = 1)
        -> (LockedUseDisplayPreflight, calls: () -> Int, wakeCalls: () -> Int) {
        var counts = activeCounts
        var reads = 0
        var wakes = 0
        var clock: TimeInterval = 0
        let preflight = LockedUseDisplayPreflight(
            activeDisplayCount: { reads += 1; return counts.removeFirst() },
            declareUserActivity: { _ in wakes += 1 },
            sleep: { _ in clock += clockStep },
            now: { clock },
            logger: Logger(subsystem: "test", category: "preflight")
        )
        return (preflight, { reads }, { wakes })
    }

    func testAwakeDisplayDoesNotWakeOrWait() {
        let (preflight, reads, wakes) = makePreflight(activeCounts: [1])
        XCTAssertEqual(preflight.wakeForAcquisition(), "alreadyAwake")
        XCTAssertEqual(reads(), 1)
        XCTAssertEqual(wakes(), 0)
    }

    func testDarkDisplayIsWokenWithRetriesUntilActive() {
        // Dark on first read and first retry, active on the second retry.
        let (preflight, _, wakes) = makePreflight(activeCounts: [0, 0, 1])
        XCTAssertEqual(preflight.wakeForAcquisition(), "woke")
        XCTAssertEqual(wakes(), 2)
    }

    func testNeverWakingStopsAtTheDeadlineAndProceedsAnyway() {
        let attempts = Int(LockedUseDisplayPreflight.wakeTimeout / LockedUseDisplayPreflight.pollInterval)
        let (preflight, _, wakes) = makePreflight(activeCounts: [Int](repeating: 0, count: attempts + 2),
                                                  clockStep: LockedUseDisplayPreflight.pollInterval)
        XCTAssertEqual(preflight.wakeForAcquisition(), "wakeTimedOut")
        XCTAssertEqual(wakes(), attempts, "wake declarations must be bounded by the timeout")
    }

    func testReleaseWaitEndsWhenGuardsReportReleased() {
        var clock: TimeInterval = 0
        let replies: [(phase: LockedUseStateMachine.Phase?, guardsReleased: Bool?)] = [
            (.idle, false), (.idle, false), (.idle, true),
        ]
        var index = 0
        let outcome = lockedUseAwaitReleasedGuards(
            status: { let reply = replies[min(index, replies.count - 1)]; index += 1; return reply },
            deadline: 4,
            poll: { _ in clock += 0.2 },
            now: { clock }
        )
        XCTAssertEqual(outcome, "ready")
        XCTAssertEqual(index, 3)
    }

    func testReleaseWaitIgnoresNonIdlePhases() {
        // Preparing means an episode is already running; the broker owns it from here.
        let outcome = lockedUseAwaitReleasedGuards(
            status: { (.preparing, nil) }, deadline: 1, poll: { _ in }, now: { 0 })
        XCTAssertEqual(outcome, "ready")
    }

    func testReleaseWaitIsBoundedAndNeverThrows() {
        var clock: TimeInterval = 0
        let outcome = lockedUseAwaitReleasedGuards(
            status: { (.idle, false) }, deadline: 1,
            poll: { _ in clock += 0.2 }, now: { clock })
        XCTAssertEqual(outcome, "releaseWaitTimedOut")
        XCTAssertEqual(clock, 1.0, accuracy: 0.001)
    }

    func testUnreachableObserverProceedsImmediately() {
        let outcome = lockedUseAwaitReleasedGuards(status: { nil }, deadline: 4,
                                                   poll: { _ in XCTFail("must not poll") }, now: { 0 })
        XCTAssertEqual(outcome, "statusUnavailable")
    }

    func testWakeReusesLatestAssertionIDAndReleasesItAfterSuccess() {
        var reads = 0
        var suppliedIDs: [IOPMAssertionID] = []
        var releasedIDs: [IOPMAssertionID] = []
        let preflight = LockedUseDisplayPreflight(
            activeDisplayCount: { reads += 1; return reads == 3 ? 1 : 0 },
            declareUserActivity: { id in suppliedIDs.append(id); id += 10 },
            releaseUserActivity: { releasedIDs.append($0) },
            sleep: { _ in }, now: { 0 })
        XCTAssertEqual(preflight.wakeForAcquisition(), "woke")
        XCTAssertEqual(suppliedIDs, [0, 10])
        XCTAssertEqual(releasedIDs, [20])
    }

    func testWakeTimeoutAlsoReleasesUserActivity() {
        var clock: TimeInterval = 0
        var releasedIDs: [IOPMAssertionID] = []
        let preflight = LockedUseDisplayPreflight(
            activeDisplayCount: { 0 },
            declareUserActivity: { $0 = 12 },
            releaseUserActivity: { releasedIDs.append($0) },
            sleep: { clock += $0 }, now: { clock })
        XCTAssertEqual(preflight.wakeForAcquisition(), "wakeTimedOut")
        XCTAssertEqual(releasedIDs, [12])
    }

    func testFailedWakeDoesNotReleaseAnInvalidAssertion() {
        var clock: TimeInterval = 0
        let preflight = LockedUseDisplayPreflight(
            activeDisplayCount: { 0 }, declareUserActivity: { _ in },
            releaseUserActivity: { _ in XCTFail("no assertion was created") },
            sleep: { clock += $0 }, now: { clock })
        XCTAssertEqual(preflight.wakeForAcquisition(), "wakeTimedOut")
    }

    func testHoldSurvivesTerminalPhaseUntilBothGuardsHaveReleased() {
        // Broker replay separately verifies both terminal phases can precede
        // the final guard ACK. Cleanup uses the ACK field, never phase alone.
        for phase in [LockedUseStateMachine.Phase.idle, .awaitingManualUnlock] {
            var releases = 0
            var reads = 0
            var clock: TimeInterval = 0
            let hold = LockedUseDisplayHold(releaseAssertion: { releases += 1 })
            let replies = [false, false, true].map {
                LockedUseIPCReply(id: UUID(), result: .ok, phase: phase, guardsReleased: $0)
            }
            let outcome = hold.waitForRelease(status: {
                XCTAssertEqual(releases, 0, "display must remain awake while checking guard ACKs")
                defer { reads += 1 }
                return replies[reads].guardsReleased
            }, poll: { clock += $0 }, now: { clock })
            XCTAssertEqual(outcome, "guardsReleased")
            XCTAssertEqual(reads, 3)
            XCTAssertEqual(releases, 1)
            hold.release()
            XCTAssertEqual(releases, 1, "cleanup must be idempotent")
        }
    }

    func testCleanupRetriesUnavailableObserverWithoutDroppingHold() {
        var clock: TimeInterval = 0
        var reads = 0
        var releases = 0
        let hold = LockedUseDisplayHold(releaseAssertion: { releases += 1 })
        let outcome = hold.waitForRelease(status: {
            XCTAssertEqual(releases, 0)
            reads += 1
            return reads < 3 ? nil : true
        }, poll: { clock += $0 }, now: { clock })
        XCTAssertEqual(outcome, "guardsReleased")
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(releases, 1)
    }

    func testStuckCleanupExpiresWithoutHoldingDisplayForever() {
        for available in [true, false] {
            var clock: TimeInterval = 0
            var releases = 0
            let hold = LockedUseDisplayHold(releaseAssertion: { releases += 1 })
            let outcome = hold.waitForRelease(status: { available ? false : nil }, timeout: 0.5,
                poll: { clock += $0 }, now: { clock })
            XCTAssertEqual(outcome, "displayReleaseWaitTimedOut")
            XCTAssertEqual(clock, 0.5, accuracy: 0.001)
            XCTAssertEqual(releases, 1)
        }
    }

    func testAlreadyReleasedGuardsNeedNoPollingDelay() {
        var releases = 0
        let hold = LockedUseDisplayHold(releaseAssertion: { releases += 1 })
        XCTAssertEqual(hold.waitForRelease(status: { true },
            poll: { _ in XCTFail("must not sleep") }, now: { 0 }), "guardsReleased")
        XCTAssertEqual(releases, 1)
    }

    func testAcquisitionConnectionErrorReleasesHoldInLongLivedClient() {
        enum Failure: Error { case connection }
        var releases = 0
        let client = LockedUseConnection(clientSocket: -1,
            prepareDisplay: { LockedUseDisplayHold(releaseAssertion: { releases += 1 }) },
            connectForAcquisition: { _ in
                XCTAssertEqual(releases, 0)
                throw Failure.connection
            })
        XCTAssertThrowsError(try client.acquire(session: .init(state: .locked, userID: 501, auditSessionID: 42)))
        XCTAssertEqual(releases, 1, "failure must release before the client connection is destroyed")
        withExtendedLifetime(client) {}
    }

    func testDisconnectDuringPreflightReleasesHoldWithoutContactingBroker() {
        var releases = 0
        var client: LockedUseConnection!
        client = LockedUseConnection(clientSocket: -1,
            prepareDisplay: {
                client.end(disconnecting: true)
                return LockedUseDisplayHold(releaseAssertion: { releases += 1 })
            }, connectForAcquisition: { _ in
                XCTFail("a cancelled preflight must not begin a lease")
                throw ComputerUseError.stateUnavailable("unexpected connection")
            })
        XCTAssertThrowsError(try client.acquire(session: .init(state: .locked, userID: 501, auditSessionID: 42)))
        XCTAssertEqual(releases, 1)
        client = nil
    }

    func testHoldDeinitReleasesAssertion() {
        var releases = 0
        var hold: LockedUseDisplayHold? = LockedUseDisplayHold(releaseAssertion: { releases += 1 })
        XCTAssertNotNil(hold)
        hold = nil
        XCTAssertEqual(releases, 1)
    }

    func testNativeHoldCreatesAndReleasesPowerAssertion() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_TEST_POWER_ASSERTIONS"] == "1" else {
            throw XCTSkip("Opt-in native assertion test; does not wake, sleep or lock the display")
        }
        guard LockedUseSession.current().state == .unlocked else {
            throw XCTSkip("Requires an already unlocked desktop")
        }
        func assertionCount() throws -> Int {
            var raw: Unmanaged<CFDictionary>?
            XCTAssertEqual(IOPMCopyAssertionsByProcess(&raw), kIOReturnSuccess)
            let assertions = try XCTUnwrap(raw).takeRetainedValue() as NSDictionary
            let owned = assertions[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
            return owned.filter { $0[kIOPMAssertionNameKey] as? String == "Open Computer Use locked session" }.count
        }
        let before = try assertionCount()
        let hold = try XCTUnwrap(LockedUseDisplayHold(logger: Logger(subsystem: "test", category: "power")))
        defer { hold.release() }
        XCTAssertEqual(try assertionCount(), before + 1)
        hold.release()
        XCTAssertEqual(try assertionCount(), before)
    }

}
