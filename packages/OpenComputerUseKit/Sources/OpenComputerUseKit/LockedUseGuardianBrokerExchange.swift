import Foundation

/// Both recovery and periodic replies can carry one-shot Broker effects.
/// Consume recovery effects before sending another report on the connection.
@MainActor
public enum LockedUseGuardianBrokerExchange {
    public enum Failure: Error { case denied }

    public static func report(
        recoveryReply: LockedUseIPCReply?,
        isFinished: () -> Bool,
        send: () async throws -> LockedUseIPCReply,
        receive: (LockedUseIPCReply) throws -> Void
    ) async throws {
        func consume(_ reply: LockedUseIPCReply) throws {
            guard !isFinished() else { return }
            guard reply.result != .denied else { throw Failure.denied }
            try receive(reply)
        }
        guard !isFinished() else { return }
        if let recoveryReply { try consume(recoveryReply) }
        guard !isFinished() else { return }
        try consume(await send())
    }
}
