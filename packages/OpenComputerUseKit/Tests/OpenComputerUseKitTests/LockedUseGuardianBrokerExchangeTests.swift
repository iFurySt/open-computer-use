import Foundation
import XCTest
@testable import OpenComputerUseKit

final class LockedUseGuardianBrokerExchangeTests: XCTestCase {
    @MainActor
    func testRecoveryEffectsPrecedeReportAndBothRepliesAreConsumed() async throws {
        var events: [String] = []
        try await LockedUseGuardianBrokerExchange.report(
            recoveryReply: .init(id: UUID(), result: .relock, phase: .relocking, effects: ["cancelUnlock", "requestRelock"]),
            isFinished: { false }, send: {
                events.append("sendReport")
                return .init(id: UUID(), result: .release, phase: .idle, effects: ["releaseGuards"])
            }, receive: { events.append(contentsOf: $0.effects) })
        XCTAssertEqual(events, ["cancelUnlock", "requestRelock", "sendReport", "releaseGuards"])
    }

    @MainActor
    func testDeniedRecoveryNeverSendsOrAppliesEffects() async {
        do {
            try await LockedUseGuardianBrokerExchange.report(
                recoveryReply: .init(id: UUID(), result: .denied, phase: .idle, effects: ["releaseGuards"]),
                isFinished: { false }, send: { XCTFail("Report after denied recovery"); throw CancellationError() },
                receive: { _ in XCTFail("Denied reply effects applied") })
            XCTFail("Denied recovery accepted")
        } catch { XCTAssertTrue(error is LockedUseGuardianBrokerExchange.Failure) }
    }

    @MainActor
    func testFinishedDuringRecoverySkipsReport() async throws {
        var finished = false
        try await LockedUseGuardianBrokerExchange.report(
            recoveryReply: .init(id: UUID(), result: .release, phase: .idle, effects: ["releaseGuards"]),
            isFinished: { finished }, send: { XCTFail("Report after completion"); throw CancellationError() },
            receive: { _ in finished = true })
        XCTAssertTrue(finished)
    }

    @MainActor
    func testFinishWhileAwaitingReportDoesNotApplyLateEffects() async throws {
        var finished = false
        try await LockedUseGuardianBrokerExchange.report(recoveryReply: nil,
            isFinished: { finished }, send: {
                finished = true
                return .init(id: UUID(), result: .relock, phase: .relocking, effects: ["requestRelock"])
            }, receive: { _ in XCTFail("Late effects after completion") })
    }

    @MainActor
    func testDeniedReportAndTransportFailurePropagate() async {
        for transportFailure in [false, true] {
            do {
                try await LockedUseGuardianBrokerExchange.report(recoveryReply: nil,
                    isFinished: { false }, send: {
                        if transportFailure { throw CancellationError() }
                        return .init(id: UUID(), result: .denied, phase: .idle, effects: ["releaseGuards"])
                    }, receive: { _ in XCTFail("Denied reply effects applied") })
                XCTFail("Failure swallowed")
            } catch {
                if transportFailure { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error is LockedUseGuardianBrokerExchange.Failure) }
            }
        }
    }
}
