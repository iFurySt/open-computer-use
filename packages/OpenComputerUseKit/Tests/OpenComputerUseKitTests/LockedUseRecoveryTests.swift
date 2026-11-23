import Foundation
@testable import OpenComputerUseKit
import XCTest

final class LockedUseRecoveryTests: XCTestCase {
    private func context(_ role: LockedUseBrokerCoordinator.Role, _ byte: UInt8) -> LockedUseBrokerCoordinator.Context {
        .init(id: UUID(), role: role, userID: 501, auditSessionID: 42,
            auditToken: Data(repeating: byte, count: 32), processID: Int32(100 + byte), codeHash: Data(repeating: byte, count: 20))
    }
    private let locked = LockedUseSession(state: .locked, userID: 501, auditSessionID: 42)
    private let unlocked = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
    private let guards = LockedUseStateMachine.Guards(allDisplaysCovered: true, inputTapHealthy: true, watchdogHealthy: true, displayGeneration: 1)

    func testAdministrativeRetirementNeedsIdleDrainAndEveryGuardExit() {
        func record(drained: Bool = true, observed: Bool = true) -> LockedUseRecoveryRecord {
            .init(leaseID: UUID(), owner: context(.agent, 1), originalClientToken: Data(repeating: 1, count: 32),
                guardian: context(.guardian, 2), watchdog: context(.guardian, 3), watchdogChallenge: nil,
                everGranted: true, observedUnlocked: observed, agentDrained: drained, fullyReleased: false)
        }
        XCTAssertTrue(record().canRetireStoppedGuards(phase: .idle, allGuardsExited: true))
        for phase in [LockedUseStateMachine.Phase.active, .authorizing, .unlocking, .relocking, .awaitingManualUnlock] {
            XCTAssertFalse(record().canRetireStoppedGuards(phase: phase, allGuardsExited: true))
        }
        XCTAssertFalse(record().canRetireStoppedGuards(phase: .idle, allGuardsExited: false))
        XCTAssertFalse(record(drained: false).canRetireStoppedGuards(phase: .idle, allGuardsExited: true))
        XCTAssertFalse(record(observed: false).canRetireStoppedGuards(phase: .idle, allGuardsExited: true))
    }

    func testWatchdogMustRegisterBeforeProductionPermitIsIssued() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true)
        let begin = try broker.handle(.init(operation: .begin, session: locked), context: owner, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        let hello = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.1)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards), context: guardian, now: 1.2)
        XCTAssertEqual(broker.phase, .preparing)
        XCTAssertThrowsError(try broker.handle(.init(operation: .watchdogHello, leaseID: lease, token: Data(repeating: 0, count: 32)), context: watchdog, now: 1.3))
        _ = try broker.handle(.init(operation: .watchdogHello, leaseID: lease, token: hello.token), context: watchdog, now: 1.4)
        let waiting = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards), context: guardian, now: 1.45)
        XCTAssertEqual(waiting.phase, .preparing)
        _ = try broker.handle(.init(operation: .watchdogReport, leaseID: lease, session: locked, guards: guards), context: watchdog, now: 1.46)
        let ready = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards), context: guardian, now: 1.5)
        XCTAssertEqual(ready.phase, .authorizing)
        XCTAssertTrue(ready.effects.contains("requestUnlock"))
    }

    func testRecoveredUngrantedLeaseRetiresAfterEveryRecordedProcessExits() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        let record = try LockedUseRecoveryRecord(leaseID: UUID(), owner: owner,
            originalClientToken: Data(repeating: 9, count: 32), guardian: guardian, watchdog: watchdog,
            watchdogChallenge: nil, everGranted: false, observedUnlocked: false,
            agentDrained: true, fullyReleased: false).validated()
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true,
            requiresWatchdog: true, recovery: record)

        for now in stride(from: 1.0, through: 600.0, by: 1.0) {
            try broker.tick(now: now)
            try broker.pollRecordedProcesses { _ in true }
        }

        XCTAssertEqual(broker.phase, .idle)
        XCTAssertTrue(broker.isFullyReleased)
        XCTAssertNil(broker.recoveryRecord(clientToken: record.originalClientToken))
        let observer = context(.observer, 4)
        let status = try broker.handle(.init(operation: .status), context: observer, now: 601)
        XCTAssertEqual(status.phase, .idle)
        let nextOwner = context(.agent, 5)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: unlocked), context: nextOwner, now: 602))
        let next = try broker.handle(.init(operation: .begin, session: locked), context: nextOwner, now: 603)
        XCTAssertEqual(next.phase, .preparing)
        XCTAssertNotEqual(next.leaseID, record.leaseID)
    }

    func testRecoveryStaysFencedUnlessEveryProcessHasExitedAndNoAllowWasGranted() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        func recovered(granted: Bool = false, observed: Bool = false) throws -> LockedUseBrokerCoordinator {
            let record = try LockedUseRecoveryRecord(leaseID: UUID(), owner: owner,
                originalClientToken: Data(repeating: 9, count: 32), guardian: guardian, watchdog: watchdog,
                watchdogChallenge: nil, everGranted: granted, observedUnlocked: observed,
                agentDrained: true, fullyReleased: false).validated()
            return .init(enabled: true, backendValidated: true, requiresWatchdog: true, recovery: record)
        }
        for unknown in [owner.processID, guardian.processID, watchdog.processID] {
            var broker = try recovered()
            try broker.pollRecordedProcesses { $0 != unknown }
            XCTAssertEqual(broker.phase, .relocking, "No exit proof for \(unknown)")
            XCTAssertFalse(broker.isFullyReleased)
        }
        for observed in [false, true] {
            var broker = try recovered(granted: true, observed: observed)
            try broker.pollRecordedProcesses { _ in true }
            XCTAssertEqual(broker.phase, .relocking, "Missing a verified relock")
            XCTAssertFalse(broker.isFullyReleased)
        }
    }

    func testOrphanRetirementPreservesInvalidatedInstallation() throws {
        let record = try LockedUseRecoveryRecord(leaseID: UUID(), owner: context(.agent, 1),
            originalClientToken: Data(repeating: 9, count: 32), guardian: nil, watchdog: nil,
            watchdogChallenge: nil, everGranted: false, observedUnlocked: false,
            agentDrained: true, fullyReleased: false).validated()
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true, recovery: record)
        try broker.invalidateInstallation()
        try broker.pollRecordedProcesses { _ in true }
        XCTAssertEqual(broker.phase, .idle)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: context(.agent, 2), now: 1))
    }

    func testAlreadyReleasedRecoveryStillNeedsMatchingManualUnlockObservation() throws {
        let record = try LockedUseRecoveryRecord(leaseID: UUID(), owner: context(.agent, 1),
            originalClientToken: Data(repeating: 9, count: 32), guardian: nil, watchdog: nil,
            watchdogChallenge: nil, everGranted: true, observedUnlocked: true,
            agentDrained: true, fullyReleased: true).validated()
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true, recovery: record)
        try broker.pollRecordedProcesses { _ in true }
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        let observer = context(.observer, 2)
        _ = try broker.handle(.init(operation: .status, session: locked), context: observer, now: 1)
        XCTAssertEqual(broker.phase, .awaitingManualUnlock)
        _ = try broker.handle(.init(operation: .status, session: unlocked), context: observer, now: 2)
        XCTAssertEqual(broker.phase, .idle)
        XCTAssertNil(broker.recoveryRecord(clientToken: record.originalClientToken))
    }

    func testRecoveryNeverReissuesPermitAndNeedsActualUnlockDrainAndRelock() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        let lease = UUID()
        let record = try LockedUseRecoveryRecord(leaseID: lease, owner: owner, originalClientToken: Data(repeating: 9, count: 32), guardian: guardian,
            watchdog: watchdog, watchdogChallenge: nil, everGranted: true, observedUnlocked: false, agentDrained: false, fullyReleased: false).validated()
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true, recovery: record)
        XCTAssertEqual(broker.phase, .relocking)
        XCTAssertThrowsError(try broker.handle(.init(operation: .begin, session: locked), context: owner, now: 1))
        let plugin = context(.plugin, 4)
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginClaim), context: plugin, now: 1.1))
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.2)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.3)
        XCTAssertEqual(broker.phase, .relocking)
        _ = try broker.handle(.init(operation: .guardianRecoveryHello, leaseID: lease, hasObservedUnlock: true), context: guardian, now: 1.4)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.5)
        let released = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.6)
        XCTAssertEqual(released.phase, .awaitingManualUnlock)
        XCTAssertTrue(released.effects.contains("releaseGuards"))
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 1.7)
        _ = try broker.handle(.init(operation: .watchdogReleased, leaseID: lease), context: watchdog, now: 1.8)
        XCTAssertTrue(broker.isFullyReleased)
        let observer = context(.observer, 5)
        _ = try broker.handle(.init(operation: .status, session: unlocked), context: observer, now: 1.9)
        XCTAssertEqual(broker.phase, .idle)
    }

    func testGuardianDeathUsesIndependentWatchdogLockEvidenceAndActionDrain() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        let lease = UUID()
        let record = try LockedUseRecoveryRecord(leaseID: lease, owner: owner, originalClientToken: Data(repeating: 9, count: 32), guardian: guardian,
            watchdog: watchdog, watchdogChallenge: nil, everGranted: true, observedUnlocked: true, agentDrained: false, fullyReleased: false).validated()
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true, recovery: record)
        try broker.guardianProcessExited()
        let beforeDrain = try broker.handle(.init(operation: .watchdogReport, leaseID: lease, session: locked), context: watchdog, now: 1)
        XCTAssertFalse(beforeDrain.effects.contains("releaseWatchdog"))
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.1)
        let afterDrain = try broker.handle(.init(operation: .watchdogReport, leaseID: lease, session: locked), context: watchdog, now: 1.2)
        XCTAssertEqual(afterDrain.phase, .awaitingManualUnlock)
        XCTAssertTrue(afterDrain.effects.contains("releaseWatchdog"))
        _ = try broker.handle(.init(operation: .watchdogReleased, leaseID: lease), context: watchdog, now: 1.3)
        XCTAssertTrue(broker.isFullyReleased)
    }

    func testRecoveryRecordRejectsUnattestedOrCrossSessionPeers() throws {
        let bare = LockedUseBrokerCoordinator.Context(id: UUID(), role: .agent, userID: 501, auditSessionID: 42)
        let bad = LockedUseRecoveryRecord(leaseID: UUID(), owner: bare, originalClientToken: Data(repeating: 1, count: 32), guardian: nil, watchdog: nil,
            watchdogChallenge: nil, everGranted: false, observedUnlocked: false, agentDrained: false, fullyReleased: true)
        XCTAssertThrowsError(try bad.validated())
        let owner = context(.agent, 1)
        let other = LockedUseBrokerCoordinator.Context(id: UUID(), role: .guardian, userID: 502, auditSessionID: 42,
            auditToken: Data(repeating: 2, count: 32), processID: 102, codeHash: Data(repeating: 2, count: 20))
        let mismatch = LockedUseRecoveryRecord(leaseID: UUID(), owner: owner, originalClientToken: Data(repeating: 1, count: 32), guardian: other, watchdog: nil,
            watchdogChallenge: nil, everGranted: false, observedUnlocked: false, agentDrained: false, fullyReleased: false)
        XCTAssertThrowsError(try mismatch.validated())
    }

    func testRecoveryProbeNeverIssuesPermitAndProductionRejectsIt() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
        var production = LockedUseBrokerCoordinator(enabled: true, backendValidated: true)
        XCTAssertThrowsError(try production.handle(.init(operation: .beginRecoveryProbe, session: locked), context: owner, now: 1))
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true,
            requiresWatchdog: true, validationMode: true)
        let begin = try broker.handle(.init(operation: .beginRecoveryProbe, session: locked), context: owner, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        let hello = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.1)
        _ = try broker.handle(.init(operation: .watchdogHello, leaseID: lease, token: hello.token), context: watchdog, now: 1.2)
        _ = try broker.handle(.init(operation: .watchdogReport, leaseID: lease, session: locked, guards: guards), context: watchdog, now: 1.3)
        let stopping = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked,
            guards: guards, unlockWorkPending: false), context: guardian, now: 1.4)
        XCTAssertEqual(stopping.phase, .relocking)
        XCTAssertEqual(stopping.recoveryProbePrepared, true)
        XCTAssertFalse(stopping.effects.contains("requestUnlock"))
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginClaim), context: context(.plugin, 4), now: 1.5))
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.6)
        let release = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked,
            guards: guards, unlockWorkPending: false), context: guardian, now: 1.7)
        XCTAssertTrue(release.effects.contains("releaseGuards"))
        XCTAssertEqual(release.guardsReleased, false)
        _ = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 1.8)
        let finished = try broker.handle(.init(operation: .watchdogReleased, leaseID: lease), context: watchdog, now: 1.9)
        XCTAssertEqual(finished.guardsReleased, true)
    }

    func testStartupFailureCannotMasqueradeAsSuccessfulDualGuardRecovery() throws {
        let owner = context(.agent, 1), guardian = context(.guardian, 2)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true,
            requiresWatchdog: true, validationMode: true)
        let begin = try broker.handle(.init(operation: .beginRecoveryProbe, session: locked), context: owner, now: 1)
        let lease = try XCTUnwrap(begin.leaseID)
        _ = try broker.handle(.init(operation: .guardianHello, leaseID: lease, token: begin.token), context: guardian, now: 1.1)
        _ = try broker.handle(.init(operation: .end, leaseID: lease), context: owner, now: 1.2)
        _ = try broker.handle(.init(operation: .quiesced, leaseID: lease), context: owner, now: 1.3)
        _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease, session: locked,
            guards: guards, unlockWorkPending: false), context: guardian, now: 1.4)
        let cleanup = try broker.handle(.init(operation: .guardianReleased, leaseID: lease), context: guardian, now: 1.5)
        XCTAssertEqual(cleanup.guardsReleased, true)
        XCTAssertEqual(cleanup.recoveryProbePrepared, false)
    }

    func testPreparingAllowsBoundedChildStartupButCannotGrantEarly() throws {
        let owner = context(.agent, 1)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true,
            requiresWatchdog: true, validationMode: true)
        _ = try broker.handle(.init(operation: .beginRecoveryProbe, session: locked), context: owner, now: 1)
        try broker.tick(now: 4.5)
        XCTAssertEqual(broker.phase, .preparing)
        XCTAssertThrowsError(try broker.handle(.init(operation: .pluginClaim), context: context(.plugin, 4), now: 4.6))
        try broker.tick(now: 1 + LockedUseStateMachine.unlockTimeout)
        XCTAssertEqual(broker.phase, .relocking)
    }

    func testFailedAgentExitReleasesGuardsOnlyAfterUnlockWorkIsDrained() throws {
        for everGranted in [false, true] {
            let owner = context(.agent, 1), guardian = context(.guardian, 2), watchdog = context(.guardian, 3)
            let lease = UUID()
            let record = try LockedUseRecoveryRecord(leaseID: lease, owner: owner,
                originalClientToken: Data(repeating: 9, count: 32), guardian: guardian,
                watchdog: watchdog, watchdogChallenge: nil, everGranted: everGranted,
                observedUnlocked: false, agentDrained: false, fullyReleased: false).validated()
            var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true,
                requiresWatchdog: true, recovery: record)
            _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease,
                session: locked, guards: guards, unlockWorkPending: true), context: guardian, now: 1)
            try broker.ownerProcessExited()
            XCTAssertEqual(broker.phase, .relocking)
            _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease,
                session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.1)
            try broker.ownerProcessExited()
            var releaseObserved = false
            if everGranted {
                XCTAssertEqual(broker.phase, .relocking, "A queued authorization allow must not expose the desktop")
                _ = try broker.handle(.init(operation: .guardianReport, leaseID: lease,
                    session: unlocked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.2)
                try broker.ownerProcessExited()
                let relocked = try broker.handle(.init(operation: .guardianReport, leaseID: lease,
                    session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.3)
                releaseObserved = relocked.effects.contains("releaseGuards")
            }
            XCTAssertEqual(broker.phase, .awaitingManualUnlock)
            let release = try broker.handle(.init(operation: .guardianReport, leaseID: lease,
                session: locked, guards: guards, unlockWorkPending: false), context: guardian, now: 1.4)
            XCTAssertTrue(releaseObserved || release.effects.contains("releaseGuards"))
        }
    }
}
