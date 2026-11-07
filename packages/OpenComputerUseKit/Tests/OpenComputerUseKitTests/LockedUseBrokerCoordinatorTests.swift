import Foundation
@testable import OpenComputerUseKit
import XCTest

final class LockedUseBrokerCoordinatorTests: XCTestCase {
    private let agent = LockedUseBrokerCoordinator.Context(id: UUID(), role: .agent, userID: 501, auditSessionID: 42)
    private let guardian = LockedUseBrokerCoordinator.Context(id: UUID(), role: .guardian, userID: 501, auditSessionID: 42)
    private let plugin = LockedUseBrokerCoordinator.Context(id: UUID(), role: .plugin, userID: 88, auditSessionID: 42)
    private let locked = LockedUseSession(state: .locked, userID: 501, auditSessionID: 42)
    private let unlocked = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
    private let healthy = LockedUseStateMachine.Guards(allDisplaysCovered: true, inputTapHealthy: true, watchdogHealthy: true, displayGeneration: 1)

    private func prepare(_ broker: inout LockedUseBrokerCoordinator) throws -> UUID {
        let begin = try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        XCTAssertEqual(begin.effects, ["prepareGuards"])
        _ = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.1)
        let ready = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy), context: guardian, now: 1.2)
        XCTAssertEqual(ready.effects, ["requestUnlock"])
        return lease
    }

    private func grant(_ broker: inout LockedUseBrokerCoordinator, lease: UUID) throws {
        let claim = try broker.handle(.init(operation: .pluginClaim), context: plugin, now: 1.3)
        let consumed = try broker.handle(.init(operation: .pluginConsume, leaseID: lease, token: claim.token), context: plugin, now: 1.4)
        XCTAssertEqual(consumed.result, .authorized)
        XCTAssertEqual(consumed.phase, .unlocking)
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginConsume, leaseID: lease, token: claim.token), context: plugin, now: 1.4))
    }

    func testStaleIdleObservationDoesNotPermanentlyDisableLeases() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        try broker.suspendForPolicyObservation()
        let begin = try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1)
        XCTAssertEqual(begin.phase, .preparing)
    }

    func testStaleObservationStopsActionsAndAllowsRecoveryBeforeAnotherLease() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let lease = try prepare(&broker)
        try grant(&broker, lease: lease)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: unlocked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.5)
        try broker.suspendForPolicyObservation()
        XCTAssertEqual(broker.phase, .relocking)
        XCTAssertThrowsError(try broker.handle(.init(operation: .action, leaseID: lease, session: unlocked), context: agent, now: 1.6))
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: agent, now: 1.7)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.8)
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 1.9)
        _ = try broker.handle(.init(operation: .status, session: unlocked), context: agent, now: 2)
        XCTAssertNoThrow(try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 2.1))
    }

    func testPermitConsumptionDoesNotAuthorizeGUIUntilObservedUnlock() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let lease = try prepare(&broker)
        try grant(&broker, lease: lease)
        XCTAssertThrowsError(try broker.handle(.init(operation: .action, leaseID: lease, session: unlocked), context: agent, now: 1.5))
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: unlocked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.6)
        let action = try broker.handle(.init(operation: .action, leaseID: lease, session: unlocked), context: agent, now: 1.7)
        XCTAssertEqual(action.result, .active)
        let foreign = LockedUseBrokerCoordinator.Context(id: UUID(), role: .agent, userID: 501, auditSessionID: 42)
        XCTAssertThrowsError(try broker.handle(.init(operation: .action, leaseID: lease, session: unlocked), context: foreign, now: 1.8))
        let status = try broker.handle(.init(operation: .status), context: foreign, now: 1.9)
        XCTAssertNotEqual(status.result, .active)
        XCTAssertNil(status.leaseID)
    }

    func testProtectedReturnRequiresGuardianIdentityInBothProfiles() throws {
        for validation in [false, true] {
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, validationMode: validation)
            let begin = try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1)
            XCTAssertEqual(begin.validationConfirmation, false)
            let hello = try broker.handle(.init(operation: .guardianHello, leaseID: begin.leaseID, token: begin.token), context: guardian, now: 1.1)
            XCTAssertEqual(hello.validationConfirmation, true)
            let status = try broker.handle(.init(operation: .status), context: agent, now: 1.2)
            XCTAssertEqual(status.validationConfirmation, false)
        }
        let old = LockedUseIPCReply(id: UUID(), result: .waiting, phase: .authorizing)
        XCTAssertNil(try JSONDecoder().decode(LockedUseIPCReply.self, from: JSONEncoder().encode(old)).validationConfirmation)
    }

    func testConsumedAllowAndOriginalLockCannotReleaseGuards() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let lease = try prepare(&broker)
        try grant(&broker, lease: lease)
        _ = try broker.handle(.init(operation: .end), context: agent, now: 1.5)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: agent, now: 1.6)
        let report = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy), context: guardian, now: 1.7)
        XCTAssertEqual(report.phase, .relocking)
        XCTAssertFalse(report.effects.contains("releaseGuards"))
    }

    func testLateUnlockIsRelockedBeforeReleaseAfterCancellation() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let lease = try prepare(&broker)
        try grant(&broker, lease: lease)
        _ = try broker.handle(.init(operation: .end), context: agent, now: 1.5)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: unlocked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.6)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: agent, now: 1.7)
        let report = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy), context: guardian, now: 1.8)
        XCTAssertEqual(report.result, .release)
        XCTAssertTrue(report.effects.contains("releaseGuards"))
    }

    func testRoleSessionChallengeAndStaleEvidenceAreRejected() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let begin = try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        XCTAssertThrowsError(try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: Data(repeating: 0, count: 32)), context: guardian, now: 1.1))
        XCTAssertThrowsError(try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: agent, now: 1.1))
        _ = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.2)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy), context: guardian, now: 1.3)
        let wrongSession = LockedUseBrokerCoordinator.Context(id: UUID(), role: .plugin, userID: 88, auditSessionID: 43)
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginClaim), context: wrongSession, now: 1.4))
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginClaim), context: plugin, now: 2.4))
    }

    func testDisconnectRevokesPendingPermit() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        _ = try prepare(&broker)
        try broker.disconnected(agent)
        XCTAssertEqual(broker.phase, .relocking)
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginClaim), context: plugin, now: 1.4))
    }

    func testNextLeaseWaitsForGuardianReleaseAcknowledgment() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let lease = try prepare(&broker)
        try grant(&broker, lease: lease)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: unlocked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.5)
        _ = try broker.handle(.init(operation: .end), context: agent, now: 1.6)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked,
            guards: healthy, stopReason: .guardLost, unlockWorkPending: false), context: guardian, now: 1.65)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: agent, now: 1.7)
        let release = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked,
            guards: healthy, stopReason: .guardLost, unlockWorkPending: false), context: guardian, now: 1.8)
        XCTAssertEqual(release.phase, .idle)
        XCTAssertTrue(release.effects.contains("releaseGuards"))
        let stopped = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked,
            guards: healthy, stopReason: .guardLost, unlockWorkPending: false), context: guardian, now: 1.85)
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertFalse(broker.isFullyReleased)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1.9))
        XCTAssertThrowsError(try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: agent, now: 2))
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 2.1)
        XCTAssertNoThrow(try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 2.2))
    }

    func testOnlyAdministratorCanFreezeNewLeasesBeforeUninstall() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        XCTAssertThrowsError(try broker.handle(.init(operation: .disable), context: agent, now: 1))
        let admin = LockedUseBrokerCoordinator.Context(id: UUID(), role: .observer, userID: 0, auditSessionID: 1)
        let reply = try broker.handle(.init(operation: .disable), context: admin, now: 1.1)
        XCTAssertEqual(reply.result, .ok)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1.2))
        var active = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        _ = try prepare(&active)
        XCTAssertThrowsError(try active.handle(.init(operation: .disable), context: admin, now: 1.3))
        XCTAssertEqual(active.phase, .authorizing)
    }

    func testChangedInstallationRevokesPermitButKeepsDrainageAvailable() throws {
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let lease = try prepare(&broker)
        let claim = try broker.handle(.init(operation: .pluginClaim), context: plugin, now: 1.3)
        try broker.invalidateInstallation()
        XCTAssertEqual(broker.phase, .relocking)
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginConsume, leaseID: lease, token: claim.token), context: plugin, now: 1.4))
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.5)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: agent, now: 1.6)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: healthy, unlockWorkPending: false), context: guardian, now: 1.7)
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 1.8)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: agent, now: 1.9))
    }

    func testUnvalidatedBackendAndForgedSessionCannotBegin() throws {
        var disabled = LockedUseBrokerCoordinator(enabled: true, backendValidated: false)
        XCTAssertThrowsError(try disabled.handle(.init(operation: .begin, session: locked), context: agent, now: 1))
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        let wrong = LockedUseSession(state: .locked, userID: 502, auditSessionID: 42)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: wrong), context: agent, now: 1))
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: guardian, now: 1))
    }
}
