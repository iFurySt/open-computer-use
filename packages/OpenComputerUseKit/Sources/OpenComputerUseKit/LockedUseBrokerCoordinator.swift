import Foundation
import Security

/// Serialized Broker control plane. The daemon supplies authenticated contexts
/// and monotonic receipt times; requests cannot choose a role, UID or audit ID.
public struct LockedUseBrokerCoordinator: Sendable {
    public enum Role: String, Codable, Sendable { case agent, guardian, plugin, observer }
    public struct Context: Codable, Sendable {
        public let id: UUID
        public let role: Role
        public let userID: UInt32
        public let auditSessionID: UInt32
        public let auditToken: Data
        public let processID: Int32
        public let codeHash: Data
        public init(id: UUID, role: Role, userID: UInt32, auditSessionID: UInt32, auditToken: Data = Data(), processID: Int32 = 0, codeHash: Data = Data()) {
            self.id = id; self.role = role; self.userID = userID; self.auditSessionID = auditSessionID
            self.auditToken = auditToken; self.processID = processID; self.codeHash = codeHash
        }
    }
    public enum Failure: Error { case denied, staleEvidence, malformed, unavailable }
    private var accepting = true
    private var unshieldedDiagnostic: LockedUseUnshieldedDiagnostic?
    private let requiresWatchdog: Bool
    private let bootSessionID: String
    private var recovering = false
    private var ownerContext: Context?
    private var guardianContext: Context?
    private var watchdogContext: Context?
    private var watchdogChallenge: Data?
    private var watchdogProtected = false
    private var watchdogLastReport: TimeInterval = 0
    private var guardianGone = false
    private var agentDrained = false
    private var machine = LockedUseStateMachine()
    private var registry = LockedUsePermitRegistry()
    private let prerequisites: LockedUseStateMachine.Prerequisites
    private var leaseID: UUID?
    private var guardianChallenge: Data?
    private var guardianID: UUID?
    private var releaseSent = false
    private var pluginID: UUID?
    private var issued: LockedUsePermitRegistry.Permit?
    private var lastReport: TimeInterval = 0
    private var guardEvidence: LockedUseStateMachine.Guards?
    private var observedSession: LockedUseSession?
    private var everGranted = false
    private var observedUnlocked = false
    private var connectionOwner: LockedUseStateMachine.Owner?
    private var receiptTime: TimeInterval = 0
    private var unlockWorkDrained = false
    private var agentEffects: [String] = []
    private var guardianEffects: [String] = []
    private let validationMode: Bool
    private var recoveryProbe = false
    private var recoveryProbePrepared = false
    public var phase: LockedUseStateMachine.Phase { unshieldedDiagnostic?.phase ?? machine.phase }
    public var stopReason: LockedUseStateMachine.StopReason? { machine.stopReason }
    public var owner: LockedUseStateMachine.Owner? { machine.owner ?? connectionOwner }

    public init(enabled: Bool, backendValidated: Bool, requiresWatchdog: Bool = false, recovery: LockedUseRecoveryRecord? = nil, bootSessionID: String = UUID().uuidString, validationMode: Bool = false) {
        self.validationMode = validationMode
        machine = .init(validationWait: validationMode)
        prerequisites = .init(enabled: enabled, backendValidated: backendValidated, clientAuthorized: true)
        self.requiresWatchdog = requiresWatchdog
        self.bootSessionID = bootSessionID
        if let recovery {
            recovering = true
            ownerContext = recovery.owner; guardianContext = recovery.guardian; watchdogContext = recovery.watchdog
            connectionOwner = .init(connectionID: recovery.owner.id, userID: recovery.owner.userID, auditSessionID: recovery.owner.auditSessionID)
            machine.restoreForRelock(owner: connectionOwner!, fullyReleased: recovery.fullyReleased)
            leaseID = recovery.leaseID; guardianID = recovery.guardian?.id
            watchdogChallenge = recovery.watchdogChallenge
            everGranted = recovery.everGranted; observedUnlocked = recovery.observedUnlocked
            agentDrained = recovery.agentDrained
            guardianGone = recovery.guardian == nil
            unlockWorkDrained = guardianGone && (!recovery.everGranted || recovery.observedUnlocked)
            agentEffects = ["stopActions"]; guardianEffects = ["cancelUnlock", "requestRelock"]
        }
    }

    public var recordedGuardian: Context? { guardianContext }
    public var recordedWatchdog: Context? { watchdogContext }
    public var recordedOwner: Context? { ownerContext }
    public var isFullyReleased: Bool { guardianContext == nil && watchdogContext == nil }
    /// Metadata only, for distinguishing unhealthy evidence from stale IPC.
    public func protectionDiagnostics(now: TimeInterval) -> (guardianAge: TimeInterval, watchdogAge: TimeInterval, watchdogProtected: Bool) {
        (max(0, now - lastReport), max(0, now - watchdogLastReport), watchdogProtected)
    }

    public func recoveryRecord(clientToken: Data) -> LockedUseRecoveryRecord? {
        guard let leaseID, let ownerContext, phase != .idle || !isFullyReleased else { return nil }
        return .init(leaseID: leaseID, owner: ownerContext, originalClientToken: clientToken,
            guardian: guardianContext, watchdog: watchdogContext, watchdogChallenge: watchdogChallenge,
            everGranted: everGranted, observedUnlocked: observedUnlocked, agentDrained: agentDrained, fullyReleased: isFullyReleased, bootSessionID: bootSessionID)
    }

    public mutating func handle(_ message: LockedUseIPCMessage, context: Context,
                                now: TimeInterval) throws -> LockedUseIPCReply {
        _ = try message.validated()
        try tick(now: now)
        if message.operation == .beginUnshieldedDiagnostic {
            guard validationMode, accepting, prerequisites.enabled, machine.phase == .idle,
                  isFullyReleased, unshieldedDiagnostic == nil, let session = message.session else { throw Failure.denied }
            unshieldedDiagnostic = try .init(owner: context, session: session, now: now)
            return unshieldedDiagnostic!.reply(message, context: context)
        }
        if var diagnostic = unshieldedDiagnostic {
            if message.operation != .disable {
                defer { unshieldedDiagnostic = diagnostic.finished ? nil : diagnostic }
                return try diagnostic.handle(message, context: context, now: now)
            }
            guard diagnostic.phase == .awaitingManualUnlock else { throw Failure.denied }
            unshieldedDiagnostic = nil
        }
        switch message.operation {
        case .beginUnshieldedDiagnostic, .endUnshieldedDiagnostic:
            throw Failure.denied
        case .status:
            // Only the owner may acknowledge a manual unlock, using a native
            // session observation matching its kernel connection identity.
            if (isOwner(context) || context.role == .observer && sameSession(context)), phase == .awaitingManualUnlock, let session = message.session {
                try check(session: session, context: context)
                try apply(machine.observe(session: session, now: now))
            }
            return reply(message, context: context)
        case .validationPassed:
            guard isOwner(context), message.leaseID == leaseID, phase == .active else { throw Failure.denied }
            try freshGuards(now: now)
            return reply(message, context: context)
        case .validationManual:
            guard context.role == .agent, sameSession(context), isFullyReleased,
                  phase == .idle || phase == .awaitingManualUnlock,
                  let session = message.session, session.state == .unlocked else { throw Failure.denied }
            try check(session: session, context: context)
            if phase == .awaitingManualUnlock { try apply(machine.observe(session: session, now: now)) }
            return reply(message, context: context)
        case .disable:
            guard context.role == .observer, context.userID == 0,
                  guardianContext == nil, watchdogContext == nil,
                  phase == .idle || phase == .awaitingManualUnlock else { throw Failure.denied }
            accepting = false
            return reply(message, context: context)
        case .begin, .beginRecoveryProbe:
            if message.operation == .beginRecoveryProbe, !validationMode { throw Failure.denied }
            guard accepting, guardianID == nil, watchdogContext == nil, context.role == .agent, let session = message.session else { throw Failure.denied }
            try check(session: session, context: context)
            let owner = LockedUseStateMachine.Owner(connectionID: context.id,
                userID: context.userID, auditSessionID: context.auditSessionID)
            let effects = try machine.begin(owner: owner, session: session, prerequisites: prerequisites, now: now)
            // A new fully released idle lease owns a fresh permit epoch. Old
            // lease ids/nonces are never accepted by the new state machine.
            registry = LockedUsePermitRegistry()
            connectionOwner = owner
            ownerContext = context; guardianContext = nil; watchdogContext = nil
            watchdogChallenge = nil; watchdogProtected = false; guardianGone = false; agentDrained = false; recovering = false
            leaseID = UUID(); guardianChallenge = try randomToken()
            guardianID = nil; releaseSent = false; pluginID = nil; issued = nil
            guardEvidence = nil; observedSession = session
            everGranted = false; observedUnlocked = false
            unlockWorkDrained = true
            recoveryProbe = message.operation == .beginRecoveryProbe
            recoveryProbePrepared = false
            agentEffects.removeAll(); guardianEffects.removeAll()
            try apply(effects)
            return reply(message, context: context, token: guardianChallenge)
        case .guardianHello:
            guard context.role == .guardian, sameSession(context), guardianID == nil,
                  phase == .preparing, message.leaseID == leaseID,
                  let token = message.token, let challenge = guardianChallenge,
                  equal(token, challenge) else { throw Failure.denied }
            guardianID = context.id; guardianContext = context; guardianChallenge = nil
            if requiresWatchdog { watchdogChallenge = try randomToken() }
            return reply(message, context: context, token: watchdogChallenge)
        case .guardianReport:
            guard isGuardian(context), message.leaseID == leaseID,
                  let session = message.session, let guards = message.guards else { throw Failure.denied }
            try check(session: session, context: context)
            observedSession = session; guardEvidence = guards; lastReport = now
            if let pending = message.unlockWorkPending { unlockWorkDrained = !pending }
            if everGranted, session.state == .unlocked { observedUnlocked = true }
            if message.stopReason == .physicalInput { try apply(machine.localInput()) }
            else if message.stopReason != nil, let owner = machine.owner {
                try apply(machine.end(owner: owner, reason: .guardLost))
            }
            if phase == .preparing {
                if !requiresWatchdog || watchdogContext != nil && watchdogProtected && now - watchdogLastReport < 1.5 {
                    if recoveryProbe {
                        guard guards.healthy, let owner else { throw Failure.denied }
                        recoveryProbePrepared = true
                        try apply(machine.end(owner: owner, reason: .operationFailed))
                    } else { try apply(machine.guardsPrepared(guards, now: now, deferPermitUntilClaim: true)) }
                }
            }
            else { try apply(machine.heartbeat(guards, now: now)) }
            if phase == .relocking, agentDrained, unlockWorkDrained, !everGranted || observedUnlocked, let owner {
                try machine.confirmQuiescence(owner: owner)
            }
            try apply(machine.observe(session: session, now: now))
            return reply(message, context: context)
        case .guardianReleased:
            guard isGuardian(context), message.leaseID == leaseID, releaseSent,
                  phase == .idle || phase == .awaitingManualUnlock else { throw Failure.denied }
            guardianID = nil; guardianContext = nil
            return reply(message, context: context)
        case .ownerRecoveryHello:
            guard isOwner(context), message.leaseID == leaseID, let session = message.session else { throw Failure.denied }
            try check(session: session, context: context)
            if guardianContext == nil { observedSession = session }
            return reply(message, context: context)
        case .guardianRecoveryHello:
            guard isGuardian(context), message.leaseID == leaseID else { throw Failure.denied }
            if everGranted, message.hasObservedUnlock == true { observedUnlocked = true }
            return reply(message, context: context)
        case .watchdogHello:
            guard context.role == .guardian, sameSession(context), message.leaseID == leaseID,
                  watchdogContext == nil, let token = message.token, let expected = watchdogChallenge,
                  equal(token, expected), phase == .preparing || recovering && phase == .relocking else { throw Failure.denied }
            watchdogContext = context; watchdogChallenge = nil; watchdogLastReport = now
            return reply(message, context: context)
        case .watchdogRecoveryHello:
            guard isWatchdog(context), message.leaseID == leaseID else { throw Failure.denied }
            if everGranted, message.hasObservedUnlock == true { observedUnlocked = true }
            return reply(message, context: context)
        case .watchdogReport:
            guard isWatchdog(context), message.leaseID == leaseID, let session = message.session else { throw Failure.denied }
            try check(session: session, context: context)
            watchdogLastReport = now
            watchdogProtected = message.guards?.healthy == true && message.stopReason == nil
            if !watchdogProtected, ![.idle, .relocking, .awaitingManualUnlock].contains(phase), let owner {
                try apply(machine.end(owner: owner, reason: .guardLost))
            }
            if everGranted, session.state == .unlocked || message.hasObservedUnlock == true { observedUnlocked = true }
            if guardianGone {
                observedSession = session; unlockWorkDrained = true
                if phase == .relocking, agentDrained, !everGranted || observedUnlocked, let owner {
                    try machine.confirmQuiescence(owner: owner)
                }
                try apply(machine.observe(session: session, now: now))
            }
            return reply(message, context: context)
        case .watchdogReleased:
            guard isWatchdog(context), message.leaseID == leaseID, releaseSent,
                  phase == .idle || phase == .awaitingManualUnlock else { throw Failure.denied }
            watchdogContext = nil
            if guardianGone { guardianID = nil; guardianContext = nil }
            return reply(message, context: context)
        case .pluginClaim:
            guard context.role == .plugin, sameAuditSession(context), phase == .authorizing,
                  pluginID == nil, observedSession?.state == .locked else { throw Failure.denied }
            try freshGuards(now: now)
            if issued == nil { try apply(machine.authorizationRequested(now: now)) }
            guard let issued else { throw Failure.denied }
            pluginID = context.id
            return reply(message, context: context, token: issued.nonce)
        case .pluginConsume:
            guard context.role == .plugin, context.id == pluginID, sameAuditSession(context),
                  message.leaseID == leaseID, let token = message.token,
                  let issued, let owner else { throw Failure.denied }
            try freshGuards(now: now)
            _ = try registry.consume(attemptID: issued.attemptID, session: issued.session,
                nonce: token, guardsHealthy: true, now: now)
            try machine.consumePermit(id: issued.attemptID, owner: owner, now: now)
            everGranted = true
            // Authorization granted is still not an active GUI lease.
            return reply(message, context: context, authorized: true)
        case .pluginFinished:
            guard context.role == .plugin, context.id == pluginID else { throw Failure.denied }
            if message.stopReason != nil, let owner { try apply(machine.end(owner: owner, reason: .operationFailed)) }
            return reply(message, context: context)
        case .action:
            guard isOwner(context), message.leaseID == leaseID,
                  let owner, let session = message.session else { throw Failure.denied }
            try check(session: session, context: context)
            try freshGuards(now: now)
            try apply(machine.authorizeAction(owner: owner, session: session, now: now))
            return reply(message, context: context)
        case .end:
            guard isOwner(context), let owner else { throw Failure.denied }
            try apply(machine.end(owner: owner, reason: message.stopReason ?? .turnEnded))
            return reply(message, context: context)
        case .quiesced:
            guard isOwner(context), let owner, message.leaseID == leaseID else { throw Failure.denied }
            // A consumed allow may still be queued in loginwindow. An old lock
            // screen is insufficient; require that unlock actually occurred
            // before accepting the action/transaction drain acknowledgement.
            guard unlockWorkDrained, !everGranted || observedUnlocked else { return reply(message, context: context) }
            agentDrained = true
            if phase == .idle || phase == .awaitingManualUnlock { return reply(message, context: context) }
            try machine.confirmQuiescence(owner: owner)
            if let session = observedSession { try apply(machine.observe(session: session, now: now)) }
            return reply(message, context: context)
        }
    }

    /// A changed authentication policy disables this service epoch. Keep the
    /// cleanup channels alive so old queued unlock work can safely drain.
    public mutating func invalidateInstallation() throws {
        accepting = false
        try suspendForPolicyObservation()
    }

    /// A slow observation stops current work without permanently invalidating
    /// an unchanged installation. New permits still require a fresh check.
    public mutating func suspendForPolicyObservation() throws {
        unshieldedDiagnostic?.cancel()
        if let owner, ![.idle, .relocking, .awaitingManualUnlock].contains(phase) {
            try apply(machine.end(owner: owner, reason: .operationFailed))
        }
    }

    public mutating func tick(now: TimeInterval) throws {
        try unshieldedDiagnostic?.tick(now: now)
        try registry.expire(now: now)
        receiptTime = now
        try apply(machine.tick(now: now))
        if requiresWatchdog, watchdogContext != nil, now - watchdogLastReport >= 1.5,
           ![.idle, .relocking, .awaitingManualUnlock].contains(phase), let owner {
            try apply(machine.end(owner: owner, reason: .guardLost))
        }
    }

    public mutating func disconnected(_ context: Context) throws {
        if context.id == unshieldedDiagnostic?.owner.id { unshieldedDiagnostic?.cancel() }
        registry.revoke(connectionID: context.id)
        if isOwner(context), let owner { try apply(machine.end(owner: owner, reason: .disconnected)) }
        else if isGuardian(context) || isWatchdog(context) || (context.id == pluginID && !everGranted), let owner {
            try apply(machine.end(owner: owner, reason: .guardLost))
        }
    }

    public mutating func guardianProcessExited() throws {
        guardianGone = true
        unlockWorkDrained = true
        if let owner, ![.idle, .awaitingManualUnlock].contains(phase) {
            try apply(machine.end(owner: owner, reason: .guardLost))
        }
    }

    /// Called only after the daemon observes ESRCH for the kernel-verified
    /// owner process. Socket closure alone cannot prove GUI dispatch drained.
    public mutating func ownerProcessExited() throws {
        guard phase == .relocking, let owner, unlockWorkDrained,
              !everGranted || observedUnlocked else { return }
        agentDrained = true
        try machine.confirmQuiescence(owner: owner)
        if let session = observedSession { try apply(machine.observe(session: session, now: receiptTime)) }
    }

    private func check(session: LockedUseSession, context: Context) throws {
        guard context.userID > 0, context.auditSessionID > 0,
              session.userID == context.userID, session.auditSessionID == context.auditSessionID else { throw Failure.denied }
    }
    private func isOwner(_ context: Context) -> Bool {
        context.role == .agent && context.id == owner?.connectionID && sameSession(context)
    }
    private func sameSession(_ context: Context) -> Bool {
        context.userID == owner?.userID && sameAuditSession(context)
    }
    private func sameAuditSession(_ context: Context) -> Bool {
        context.auditSessionID > 0 && context.auditSessionID == owner?.auditSessionID
    }
    private func isWatchdog(_ context: Context) -> Bool {
        context.role == .guardian && context.id == watchdogContext?.id && sameSession(context)
    }
    private func isGuardian(_ context: Context) -> Bool {
        context.role == .guardian && context.id == guardianID && sameSession(context)
    }
    private func freshGuards(now: TimeInterval) throws {
        guard now >= lastReport, now - lastReport < 1,
              guardEvidence?.healthy == true, observedSession?.state != .unavailable,
              !requiresWatchdog || watchdogContext != nil && watchdogProtected && now - watchdogLastReport < 1.5 else { throw Failure.staleEvidence }
    }
    private mutating func apply(_ effects: [LockedUseStateMachine.Effect]) throws {
        for effect in effects {
            switch effect {
            case .prepareGuards: agentEffects.append("prepareGuards")
            case let .issuePermit(permit):
                issued = try registry.issue(attemptID: permit.id, connectionID: permit.owner.connectionID,
                    session: .init(userID: permit.owner.userID, auditSessionID: permit.owner.auditSessionID),
                    guardsHealthy: true, now: receiptTime)
            case .requestUnlock:
                unlockWorkDrained = false
                guardianEffects.append("requestUnlock")
            case .stopActions: agentEffects.append("stopActions")
            case .revokePermit:
                if let issued { registry.revoke(attemptID: issued.attemptID) }
                issued = nil
            case .cancelUnlock: guardianEffects.append("cancelUnlock")
            case .requestRelock: guardianEffects.append("requestRelock")
            case .releaseGuards: guardianEffects.append("releaseGuards")
            }
        }
    }
    private mutating func reply(_ message: LockedUseIPCMessage, context: Context,
                               token: Data? = nil, authorized: Bool = false) -> LockedUseIPCReply {
        var effects: [String] = []
        if isOwner(context) { effects = agentEffects; agentEffects.removeAll() }
        if isGuardian(context) {
            effects = guardianEffects; guardianEffects.removeAll()
            if effects.contains("releaseGuards") { releaseSent = true }
        }
        if isWatchdog(context), releaseSent || guardianGone && guardianEffects.contains("releaseGuards") {
            if guardianGone { guardianEffects.removeAll { $0 == "releaseGuards" }; releaseSent = true }
            effects.append("releaseWatchdog")
        }
        let result: LockedUseIPCReply.Result = effects.contains("releaseGuards") ? .release
            : authorized ? .authorized : phase == .active && isOwner(context) ? .active : phase == .relocking ? .relock
            : phase == .idle ? .ok : .waiting
        return .init(id: message.id, result: result, phase: phase,
            leaseID: isOwner(context) || isGuardian(context) || isWatchdog(context) || context.id == pluginID ? leaseID : nil,
            token: token, effects: effects, guardsReleased: isFullyReleased,
            recoveryProbePrepared: recoveryProbe ? recoveryProbePrepared : nil, startupDeadline: machine.startupDeadline,
            validationConfirmation: isGuardian(context))
    }
    private func randomToken() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        return Data(bytes)
    }
    private func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 32, rhs.count == 32 else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
