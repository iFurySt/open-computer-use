import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Composes production policies with synthetic OS observations and a virtual clock.
/// No system lock, credentials, privileged service or GUI is used here.
final class LockedUseIncidentReplayTests: XCTestCase {
    private struct Replay {
        let agent = LockedUseBrokerCoordinator.Context(id: UUID(), role: .agent, userID: 501, auditSessionID: 42)
        let guardian = LockedUseBrokerCoordinator.Context(id: UUID(), role: .guardian, userID: 501, auditSessionID: 42)
        let watchdog = LockedUseBrokerCoordinator.Context(id: UUID(), role: .guardian, userID: 501, auditSessionID: 42)
        let plugin = LockedUseBrokerCoordinator.Context(id: UUID(), role: .plugin, userID: 88, auditSessionID: 42)
        let locked = LockedUseSession(state: .locked, userID: 501, auditSessionID: 42)
        let unlocked = LockedUseSession(state: .unlocked, userID: 501, auditSessionID: 42)
        let healthy = LockedUseStateMachine.Guards(allDisplaysCovered: true, inputTapHealthy: true, watchdogHealthy: true, displayGeneration: 1)
        var broker = LockedUseBrokerCoordinator(enabled: true, backendValidated: true, requiresWatchdog: true)
        var policy: LockedUseGuardianPolicy
        var lease: UUID!

        init() throws {
            policy = try LockedUseGuardianPolicy(session: locked, now: 1)
            try policy.prepared(topology: "display", now: 1)
            let begin = try send(.init(operation: .begin, session: locked), agent, 1)
            lease = try XCTUnwrap(begin.leaseID)
            let hello = try send(.init(operation: .guardianHello, leaseID: lease, token: begin.token), guardian, 1.1)
            _ = try send(.init(operation: .watchdogHello, leaseID: lease, token: hello.token), watchdog, 1.2)
            _ = try send(.init(operation: .watchdogReport, leaseID: lease, session: locked, guards: healthy), watchdog, 1.25)
            _ = try report(locked, 1.3)
            let claim = try send(.init(operation: .pluginClaim), plugin, 1.35)
            _ = try send(.init(operation: .pluginConsume, leaseID: lease, token: claim.token), plugin, 1.4)
            _ = try report(unlocked, 1.5)
            XCTAssertEqual(broker.phase, .active)
            // Keep both guards alive so the actual idle timer, not guard loss,
            // causes the transition reported in issue #157.
            for second in 2...31 {
                let now = Double(second)
                _ = try policy.heartbeat(now: now)
                _ = try send(.init(operation: .watchdogReport, leaseID: lease, session: unlocked, guards: healthy), watchdog, now)
                _ = try report(unlocked, now + 0.1)
            }
            let stop = try send(.init(operation: .status), agent, 31.5)
            XCTAssertEqual(stop.phase, .relocking)
            XCTAssertEqual(broker.stopReason, .idleTimeout)
            XCTAssertTrue(stop.effects.contains("stopActions"))
            XCTAssertEqual(policy.stop(.stopRequested, now: 31.5), [.requestRelock])
            _ = try report(locked, 31.6, stopped: true)
            XCTAssertEqual(try poll(locked, 31.65), [])
            _ = try send(.init(operation: .quiesced, leaseID: lease), agent, 31.7)
            XCTAssertEqual(broker.phase, .idle)
            XCTAssertFalse(broker.isFullyReleased)
        }

        mutating func send(_ message: LockedUseIPCMessage, _ peer: LockedUseBrokerCoordinator.Context, _ now: Double) throws -> LockedUseIPCReply {
            // Exercise the actual wire Codable representations, without claiming
            // to test socket authentication or operating-system observations.
            let decoded = try JSONDecoder().decode(LockedUseIPCMessage.self, from: JSONEncoder().encode(message))
            let reply = try broker.handle(decoded, context: peer, now: now)
            return try JSONDecoder().decode(LockedUseIPCReply.self, from: JSONEncoder().encode(reply))
        }
        mutating func report(_ session: LockedUseSession, _ now: Double, stopped: Bool = false) throws -> LockedUseIPCReply {
            try send(.init(operation: .guardianReport, leaseID: lease, session: session, guards: healthy,
                           stopReason: stopped ? .guardLost : nil, unlockWorkPending: false), guardian, now)
        }
        mutating func poll(_ session: LockedUseSession, _ now: Double) throws -> [LockedUseGuardianPolicy.Effect] {
            try policy.poll(session: session, topology: "display", guardsHealthy: true, lockPresentationReady: true, now: now)
        }
    }

    func testIdleTimeoutReleasesBothGuardsAndDoesNotRelockUser() throws {
        for mainFirst in [true, false] {
            var r = try Replay()
            let wrongGuardian = LockedUseBrokerCoordinator.Context(id: UUID(), role: .guardian, userID: 501, auditSessionID: 42)
            XCTAssertThrowsError(try r.send(.init(operation: .guardianReport, leaseID: r.lease, session: r.locked,
                guards: r.healthy, stopReason: .guardLost), wrongGuardian, 31.71))
            XCTAssertThrowsError(try r.send(.init(operation: .guardianReport, leaseID: UUID(), session: r.locked,
                guards: r.healthy, stopReason: .guardLost), r.guardian, 31.72))
            XCTAssertThrowsError(try r.send(.init(operation: .begin, session: r.locked), r.agent, 31.73))
            // On main this throws clientUnauthorized before delivering release.
            let release = try r.report(r.locked, 31.8, stopped: true)
            XCTAssertTrue(release.effects.contains("releaseGuards"))
            // Same release effect mapping as DisplayGuardian.reportToBroker.
            r.policy.confirmQuiescence()
            _ = r.policy.stop(.stopRequested, now: 31.8)
            XCTAssertEqual(try r.poll(r.locked, 32), [.releaseShield])
            XCTAssertEqual(r.policy.phase, .finished)
            XCTAssertEqual(try r.poll(r.unlocked, 32.6), [])
            let watchdog = try r.send(.init(operation: .watchdogReport, leaseID: r.lease, session: r.locked,
                guards: r.healthy), r.watchdog, 32.7)
            XCTAssertTrue(watchdog.effects.contains("releaseWatchdog"))
            let acknowledgements: [(LockedUseIPCMessage.Operation, LockedUseBrokerCoordinator.Context)] = mainFirst
                ? [(.guardianReleased, r.guardian), (.watchdogReleased, r.watchdog)]
                : [(.watchdogReleased, r.watchdog), (.guardianReleased, r.guardian)]
            _ = try r.send(.init(operation: acknowledgements[0].0, leaseID: r.lease), acknowledgements[0].1, 32.8)
            XCTAssertFalse(r.broker.isFullyReleased)
            XCTAssertThrowsError(try r.send(.init(operation: .begin, session: r.locked), r.agent, 32.9))
            _ = try r.send(.init(operation: acknowledgements[1].0, leaseID: r.lease), acknowledgements[1].1, 33)
            XCTAssertTrue(r.broker.isFullyReleased)
            XCTAssertEqual(try r.send(.init(operation: .begin, session: r.locked), r.agent, 33.1).phase, .preparing)
        }
    }

    @MainActor
    func testReconnectConsumesReleaseBeforeNextReport() async throws {
        var r = try Replay()
        let hello = try r.send(.init(operation: .guardianRecoveryHello, leaseID: r.lease,
            hasObservedUnlock: true), r.guardian, 31.75)
        XCTAssertTrue(hello.effects.contains("releaseGuards"))
        var time = 31.75
        try await LockedUseGuardianBrokerExchange.report(recoveryReply: hello,
            isFinished: { r.policy.phase == .finished },
            send: {
                // This reply has no release effect: the hello already drained it.
                time = 31.8
                return try r.report(r.locked, time, stopped: true)
            }, receive: { reply in
                if reply.effects.contains("releaseGuards") {
                    r.policy.confirmQuiescence()
                    _ = r.policy.stop(.stopRequested, now: time)
                }
            })
        XCTAssertEqual(try r.poll(r.locked, 32), [.releaseShield])
        XCTAssertEqual(try r.poll(r.unlocked, 32.6), [])
        let watchdog = try r.send(.init(operation: .watchdogReport, leaseID: r.lease,
            session: r.locked, guards: r.healthy), r.watchdog, 32.7)
        XCTAssertTrue(watchdog.effects.contains("releaseWatchdog"))
        _ = try r.send(.init(operation: .watchdogReleased, leaseID: r.lease), r.watchdog, 32.8)
        XCTAssertFalse(r.broker.isFullyReleased)
        XCTAssertThrowsError(try r.send(.init(operation: .begin, session: r.locked), r.agent, 33))
        XCTAssertEqual(r.policy.phase, .finished)
        _ = try r.send(.init(operation: .guardianReleased, leaseID: r.lease), r.guardian, 33.1)
        XCTAssertTrue(r.broker.isFullyReleased)
        XCTAssertEqual(try r.send(.init(operation: .begin, session: r.locked), r.agent, 33.2).phase, .preparing)
    }
}
