import Foundation

/// Pure policy for the macOS experiment. Effects are commands, never evidence
/// that the operating system has actually unlocked or locked the desktop.
/// A future Broker must serialize events and execute these effects independently
/// of tool execution; callbacks must not wait for an in-flight GUI action.
public struct LockedUseStateMachine: Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, preparing, authorizing, unlocking, active, relocking, awaitingManualUnlock
    }

    public enum StopReason: String, Codable, Sendable {
        case turnEnded, disconnected, idleTimeout, leaseExpired, physicalInput
        case guardLost, unlockTimeout, sessionChanged, operationFailed
    }

    public enum Effect: Equatable, Sendable {
        case prepareGuards
        case issuePermit(Permit)
        case requestUnlock
        case stopActions
        case revokePermit
        case cancelUnlock
        case requestRelock
        case releaseGuards
    }

    public struct Owner: Equatable, Sendable {
        /// Issued by verified IPC, not taken from request metadata or environment.
        public let connectionID: UUID
        public let userID: UInt32
        public let auditSessionID: UInt32

        public init(connectionID: UUID, userID: UInt32, auditSessionID: UInt32) {
            self.connectionID = connectionID
            self.userID = userID
            self.auditSessionID = auditSessionID
        }
    }

    public struct Permit: Equatable, Sendable {
        public let id: UUID
        public let owner: Owner
        public let deadline: TimeInterval
    }

    public struct Guards: Equatable, Codable, Sendable {
        public let allDisplaysCovered: Bool
        public let inputTapHealthy: Bool
        public let watchdogHealthy: Bool
        public let displayGeneration: UInt64

        public init(allDisplaysCovered: Bool, inputTapHealthy: Bool, watchdogHealthy: Bool, displayGeneration: UInt64) {
            self.allDisplaysCovered = allDisplaysCovered
            self.inputTapHealthy = inputTapHealthy
            self.watchdogHealthy = watchdogHealthy
            self.displayGeneration = displayGeneration
        }

        public var healthy: Bool { allDisplaysCovered && inputTapHealthy && watchdogHealthy }
    }

    public struct Prerequisites: Sendable {
        public let enabled: Bool
        public let backendValidated: Bool
        public let clientAuthorized: Bool

        public init(enabled: Bool, backendValidated: Bool, clientAuthorized: Bool) {
            self.enabled = enabled
            self.backendValidated = backendValidated
            self.clientAuthorized = clientAuthorized
        }
    }

    public enum Failure: String, Error, LocalizedError, Sendable {
        case disabled, backendUnvalidated, clientUnauthorized, invalidSession
        case busy, manualUnlockRequired, invalidTransition, invalidClock, invalidPermit, guardsUnhealthy

        public var errorDescription: String? { "Locked Use: \(rawValue)" }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var owner: Owner?
    public private(set) var permit: Permit?
    public private(set) var stopReason: StopReason?
    private var guards: Guards?
    private var permitConsumed = false
    private var startedAt: TimeInterval = 0
    private var lastActivityAt: TimeInterval = 0
    private var lastHeartbeatAt: TimeInterval = 0
    private var lastEventAt: TimeInterval = 0
    private var requiresManualUnlock = false
    private var quiesced = false

    public static let idleTimeout: TimeInterval = 30
    public static let permitLifetime: TimeInterval = 5
    public static let unlockTimeout: TimeInterval = 8
    public static let validationUnlockTimeout: TimeInterval = 20
    private let startupTimeout: TimeInterval
    public var startupDeadline: TimeInterval? {
        [.preparing, .authorizing, .unlocking].contains(phase) ? startedAt + startupTimeout : nil
    }
    public static let heartbeatTimeout: TimeInterval = 3
    public static let maximumLease: TimeInterval = 300

    public init(validationWait: Bool = false) {
        startupTimeout = validationWait ? Self.validationUnlockTimeout : Self.unlockTimeout
    }

    public mutating func restoreForRelock(owner: Owner, fullyReleased: Bool) {
        reset()
        self.owner = owner
        phase = fullyReleased ? .awaitingManualUnlock : .relocking
        requiresManualUnlock = true
        stopReason = .disconnected
    }

    /// `now` must be monotonic uptime. Wall-clock timestamps cannot extend leases.
    public mutating func begin(owner candidate: Owner, session: LockedUseSession, prerequisites: Prerequisites, now: TimeInterval) throws -> [Effect] {
        try checkClock(now)
        guard phase != .awaitingManualUnlock else { throw Failure.manualUnlockRequired }
        guard phase == .idle else { throw Failure.busy }
        guard prerequisites.enabled else { throw Failure.disabled }
        guard prerequisites.backendValidated else { throw Failure.backendUnvalidated }
        guard prerequisites.clientAuthorized else { throw Failure.clientUnauthorized }
        guard session.state == .locked, matches(session, owner: candidate) else { throw Failure.invalidSession }
        owner = candidate
        phase = .preparing
        startedAt = now
        lastActivityAt = now
        lastHeartbeatAt = now
        stopReason = nil
        requiresManualUnlock = false
        return [.prepareGuards]
    }

    public mutating func guardsPrepared(_ evidence: Guards, now: TimeInterval, deferPermitUntilClaim: Bool = false) throws -> [Effect] {
        try checkClock(now)
        guard phase == .preparing, let owner else { throw Failure.invalidTransition }
        guard now - startedAt < Self.unlockTimeout else { return stop(.unlockTimeout) }
        guard evidence.healthy else { return stop(.guardLost) }
        guards = evidence
        lastHeartbeatAt = now
        phase = .authorizing
        if deferPermitUntilClaim { return [.requestUnlock] }
        let issued = Permit(id: UUID(), owner: owner, deadline: now + Self.permitLifetime)
        permit = issued
        return [.issuePermit(issued), .requestUnlock]
    }

    /// Only an authenticated mechanism claim can convert protected waiting into
    /// a permit. The overall startup deadline is never restarted or extended.
    public mutating func authorizationRequested(now: TimeInterval) throws -> [Effect] {
        try checkClock(now)
        guard phase == .authorizing, permit == nil, !permitConsumed, let owner,
              guards?.healthy == true, now - lastHeartbeatAt < Self.heartbeatTimeout,
              now - startedAt < startupTimeout else { throw Failure.invalidTransition }
        let issued = Permit(id: UUID(), owner: owner, deadline: min(now + Self.permitLifetime, startedAt + startupTimeout))
        permit = issued
        return [.issuePermit(issued)]
    }

    /// Called only by the authenticated Broker when the plugin consumes a permit.
    /// Evaluation of an authorization right alone cannot activate the session.
    public mutating func consumePermit(id: UUID, owner candidate: Owner, now: TimeInterval) throws {
        try checkClock(now)
        guard phase == .authorizing, let permit, !permitConsumed,
              permit.id == id, permit.owner == candidate, now < permit.deadline else {
            throw Failure.invalidPermit
        }
        permitConsumed = true
        phase = .unlocking
    }

    public mutating func observe(session: LockedUseSession, now: TimeInterval) throws -> [Effect] {
        try checkClock(now)
        if phase == .awaitingManualUnlock {
            // The backend may send this event only after observing a normal user
            // unlock with no OCU permit. Merely starting a new tool is insufficient.
            if session.state == .unlocked, let owner, matches(session, owner: owner) {
                reset()
            }
            return []
        }
        guard phase != .idle, let owner else { return [] }
        // Unknown / different sessions never count as relock confirmation.
        guard matches(session, owner: owner), session.state != .unavailable else {
            return phase == .relocking ? [] : stop(.sessionChanged)
        }
        if phase == .relocking, session.state == .locked {
            // A lock observation during a still-pending unlock attempt may be
            // the original lock screen. Keep shielding until the Broker has
            // drained/cancelled that attempt and stopped action dispatch.
            guard quiesced else { return [] }
            let effects: [Effect] = [.releaseGuards]
            if requiresManualUnlock {
                phase = .awaitingManualUnlock
                permit = nil
                guards = nil
            } else {
                reset()
            }
            return effects
        }
        if phase == .unlocking, session.state == .unlocked {
            guard now - startedAt < startupTimeout,
                  now - lastHeartbeatAt < Self.heartbeatTimeout,
                  guards?.healthy == true, permitConsumed else {
                return stop(.unlockTimeout)
            }
            phase = .active
            lastActivityAt = now
            return [.revokePermit]
        }
        if phase == .active, session.state != .unlocked { return stop(.sessionChanged) }
        if [.preparing, .authorizing].contains(phase), session.state == .unlocked {
            return stop(.sessionChanged)
        }
        return []
    }

    public mutating func heartbeat(_ evidence: Guards, now: TimeInterval) throws -> [Effect] {
        try checkClock(now)
        guard [.preparing, .authorizing, .unlocking, .active].contains(phase) else { return [] }
        guard evidence.healthy else { return stop(.guardLost) }
        if let guards, evidence.displayGeneration != guards.displayGeneration {
            return stop(.guardLost)
        }
        // A late heartbeat cannot resurrect a dead watchdog / expired lease.
        let expired = try tick(now: now)
        guard expired.isEmpty else { return expired }
        lastHeartbeatAt = now
        return []
    }

    /// Check immediately before each action; an old AX snapshot is not a lease.
    public mutating func authorizeAction(owner candidate: Owner, session: LockedUseSession, now: TimeInterval) throws -> [Effect] {
        try checkClock(now)
        guard phase == .active, owner == candidate else { throw Failure.invalidTransition }
        let expired = try tick(now: now)
        guard expired.isEmpty else { return expired }
        guard session.state == .unlocked, matches(session, owner: candidate) else { return stop(.sessionChanged) }
        lastActivityAt = now
        return []
    }

    public mutating func end(owner candidate: Owner, reason: StopReason) throws -> [Effect] {
        guard owner == candidate else { throw Failure.clientUnauthorized }
        return stop(reason)
    }

    /// Called out of band. The triggering event is swallowed before it reaches apps.
    public mutating func localInput() -> [Effect] { stop(.physicalInput) }

    public mutating func tick(now: TimeInterval) throws -> [Effect] {
        try checkClock(now)
        guard [.preparing, .authorizing, .unlocking, .active].contains(phase) else { return [] }
        if phase != .preparing, now - lastHeartbeatAt >= Self.heartbeatTimeout { return stop(.guardLost) }
        if now - startedAt >= Self.maximumLease { return stop(.leaseExpired) }
        if phase == .active, now - lastActivityAt >= Self.idleTimeout { return stop(.idleTimeout) }
        if phase == .preparing, now - startedAt >= Self.unlockTimeout { return stop(.unlockTimeout) }
        if phase != .active, now - startedAt >= startupTimeout { return stop(.unlockTimeout) }
        if phase == .authorizing, let permit, now >= permit.deadline { return stop(.unlockTimeout) }
        return []
    }

    /// Authenticated Broker acknowledgement: permit revocation is committed,
    /// no unlock request can still complete, and action dispatch is drained.
    /// Merely sending cancel / stop effects does not satisfy this barrier.
    public mutating func confirmQuiescence(owner candidate: Owner) throws {
        guard phase == .relocking, owner == candidate else { throw Failure.invalidTransition }
        quiesced = true
    }

    /// Recovered relock barrier for a lease that never granted an unlock, once
    /// every recorded process has exited. Nothing is left to report the session,
    /// and OCU never unlocked the desktop, so hold for a normal manual unlock
    /// instead of relocking for the rest of the boot.
    public mutating func abandonUngrantedRelock() -> [Effect] {
        guard phase == .relocking, quiesced else { return [] }
        phase = .awaitingManualUnlock
        requiresManualUnlock = true
        permit = nil
        guards = nil
        return [.releaseGuards]
    }

    /// If relock failed, retain shielding and retry; never release on a timer.
    public func retryRelock() -> [Effect] { phase == .relocking ? [.requestRelock] : [] }

    private mutating func stop(_ reason: StopReason) -> [Effect] {
        guard [.preparing, .authorizing, .unlocking, .active].contains(phase) else { return [] }
        phase = .relocking
        quiesced = false
        stopReason = reason
        requiresManualUnlock = ![.turnEnded, .disconnected, .idleTimeout, .leaseExpired].contains(reason)
        return [.stopActions, .revokePermit, .cancelUnlock, .requestRelock]
    }

    private func matches(_ session: LockedUseSession, owner: Owner) -> Bool {
        session.userID == owner.userID && session.auditSessionID == owner.auditSessionID
    }

    private mutating func checkClock(_ now: TimeInterval) throws {
        guard now.isFinite, now >= lastEventAt else { throw Failure.invalidClock }
        lastEventAt = now
    }

    private mutating func reset() {
        phase = .idle
        owner = nil
        permit = nil
        guards = nil
        permitConsumed = false
        stopReason = nil
        requiresManualUnlock = false
        quiesced = false
    }
}
