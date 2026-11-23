import Foundation
@testable import OpenComputerUseKit
import XCTest

/// A recovered lease whose owner, Guardian and watchdog processes are all gone
/// must not keep the Broker in `relocking` for the rest of the boot.
final class LockedUseStaleRecoveryTests: XCTestCase {
    private func ctx(_ role: LockedUseBrokerCoordinator.Role, pid: Int32) -> LockedUseBrokerCoordinator.Context {
        .init(id: UUID(), role: role, userID: 501, auditSessionID: 100003,
              auditToken: Data(repeating: 1, count: 32), processID: pid, codeHash: Data([1]))
    }

    private func recovered(everGranted: Bool, observedUnlocked: Bool) throws -> LockedUseBrokerCoordinator {
        // Shape of a real record left by an interrupted locked turn.
        let record = LockedUseRecoveryRecord(
            leaseID: UUID(), owner: ctx(.agent, pid: 12614), originalClientToken: Data(repeating: 2, count: 32),
            guardian: ctx(.guardian, pid: 86342), watchdog: ctx(.guardian, pid: 86370), watchdogChallenge: nil,
            everGranted: everGranted, observedUnlocked: observedUnlocked, agentDrained: true, fullyReleased: false)
        return LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true,
                                          recovery: try record.validated())
    }

    /// What BrokerMain's timer does once kill(pid, 0) reports ESRCH for each recorded process.
    private func runTimer(_ broker: inout LockedUseBrokerCoordinator) throws {
        for t in stride(from: 1.0, through: 600.0, by: 1.0) {
            try broker.tick(now: t)
            try broker.guardianProcessExited()
            try broker.ownerProcessExited()
        }
    }

    func testUngrantedRecoveredLeaseWithAllProcessesGoneWaitsForManualUnlock() throws {
        var broker = try recovered(everGranted: false, observedUnlocked: false)
        XCTAssertEqual(broker.phase, .relocking)
        try runTimer(&broker)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock,
                       "recovered lease with no live owner/Guardian/watchdog stays relocking; every unscoped GUI call is refused")
        // A new lease is still refused until a normal manual unlock.
        let agent = LockedUseBrokerCoordinator.Context(id: UUID(), role: .agent, userID: 501, auditSessionID: 100003)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin,
            session: .init(state: .locked, userID: 501, auditSessionID: 100003)), context: agent, now: 700))
    }

    func testGrantedRecoveredLeaseWithoutObservedUnlockKeepsRelocking() throws {
        // OCU may have unlocked the desktop; without evidence it must not release the barrier.
        var broker = try recovered(everGranted: true, observedUnlocked: false)
        try runTimer(&broker)
        XCTAssertEqual(broker.phase, .relocking)
    }

    func testGrantedRecoveredLeaseWithObservedUnlockKeepsRelocking() throws {
        // OCU did unlock the desktop: only a real relock observation may release it.
        var broker = try recovered(everGranted: true, observedUnlocked: true)
        try runTimer(&broker)
        XCTAssertEqual(broker.phase, .relocking)
    }
}
