import XCTest
import os
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
            declareUserActivity: { wakes += 1 },
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
}
