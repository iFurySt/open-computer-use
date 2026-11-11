import Darwin
import Foundation
import OpenComputerUseKit
import os

/// One authenticated Broker connection per app-agent client. Only GUI requests
/// acquire a lease; inventory, diagnostics and protocol discovery do not unlock.
final class LockedUseConnection: @unchecked Sendable {
    private let mutex = NSLock()
    private let logger = Logger(subsystem: "dev.opencomputeruse.locked-use", category: "AgentRecovery")
    private let clientSocket: Int32
    private var broker: LockedUseIPCClient?
    private var lease: UUID?
    private var guardian: Process?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var clientDisconnected = false
    private var inFlight = false
    private var validationLease: UUID?
    private var recoveryProbeStarted = false
    private var displayHold: LockedUseDisplayHold?
    private let preflightLogger = Logger(subsystem: "dev.opencomputeruse.locked-use", category: "DisplayPreflight")
    private let recoveryDeadline = LockedUseRecoveryDeadline {
        // Exit our own automation agent, not the Guardian/watchdog or a user
        // application. Root still requires observed lock and unlock-work drain
        // before either shield can be released.
        fputs("Locked Use recovery deadline expired; stopping automation agent.\n", stderr)
        _exit(70)
    }

    init(clientSocket: Int32) {
        self.clientSocket = dup(clientSocket)
        if self.clientSocket >= 0 { _ = fcntl(self.clientSocket, F_SETFD, FD_CLOEXEC) }
    }
    deinit { if clientSocket >= 0 { Darwin.close(clientSocket) } }

    func perform<T>(_ body: () throws -> T) throws -> T {
        let session = LockedUseSession.current()
        mutex.lock(); let needsRecovery = stopped && lease == nil; mutex.unlock()
        if session.state == .unlocked, needsRecovery || FileManager.default.fileExists(atPath: LockedUseIPCEndpoint.observer.path) {
            _ = try observeManualUnlock()
        }
        if session.state == .locked { try acquire(session: session) }
        mutex.lock()
        guard !stopped && !clientDisconnected else { mutex.unlock(); throw ComputerUseError.stateUnavailable("Locked Use stopped. Unlock the Mac normally before starting another session.") }
        let scoped = lease != nil
        inFlight = true
        mutex.unlock()
        defer {
            mutex.lock(); inFlight = false; let drain = stopped; mutex.unlock()
            if drain { acknowledgeDrain() }
        }
        if scoped {
            return try LockedUseActionScope.withValidator({ [self] in try validateAction() }, body: body)
        }
        return try body()
    }

    private func acquire(session: LockedUseSession, recoveryProbe: Bool = false) throws {
        mutex.lock(); let existing = lease; let denied = stopped || clientDisconnected; mutex.unlock()
        if existing != nil || denied { try validateAction(); return }
        // Dark-display insurance before the broker's startup deadline starts counting:
        // wake a sleeping display and keep it awake through the whole episode. See
        // LockedUseDisplayPreflight for the failure modes this prevents.
        _ = LockedUseDisplayPreflight(logger: preflightLogger).wakeForAcquisition()
        mutex.lock(); if displayHold == nil { displayHold = LockedUseDisplayHold(logger: preflightLogger) }; mutex.unlock()
        _ = lockedUseAwaitReleasedGuards(status: releasedGuardsStatus)
        let connection = try LockedUseIPCClient(endpoint: .agent,
            brokerRequirement: LockedUseSigningIdentity.brokerRequirement(), clientSocket: clientSocket)
        let reply = try connection.request(.init(operation: recoveryProbe ? .beginRecoveryProbe : .begin, session: session))
        let now = ProcessInfo.processInfo.systemUptime
        let startupDeadline = reply.startupDeadline ?? now + LockedUseStateMachine.unlockTimeout
        guard reply.result != .denied, reply.phase == .preparing,
              startupDeadline.isFinite, startupDeadline > now,
              startupDeadline <= now + LockedUseStateMachine.validationUnlockTimeout,
              let lease = reply.leaseID, let token = reply.token else {
            connection.close()
            // No episode started; don't strand a display assertion in a long-lived agent.
            mutex.lock(); displayHold?.release(); displayHold = nil; mutex.unlock()
            throw ComputerUseError.stateUnavailable("Locked Use is unavailable. Enable and validate it in Open Computer Use settings.")
        }
        mutex.lock(); broker = connection; self.lease = lease; let disconnected = clientDisconnected; mutex.unlock()
        if recoveryProbe { mutex.lock(); recoveryProbeStarted = true; mutex.unlock() }
        // Follow the authenticated root's bounded deadline, plus its existing
        // two-second RPC budget for stop/drain. The client cannot extend it.
        recoveryDeadline.arm(after: startupDeadline - now + 2)
        do {
            guard !disconnected else { throw ComputerUseError.stateUnavailable("Computer Use client disconnected during lease acquisition.") }
            let child = Process()
            // The installer fixes this location; caller arguments cannot select
            // another guardian or executable while holding a capability.
            child.executableURL = URL(fileURLWithPath: "/Library/Application Support/OpenComputerUse/LockedUse/OCU Guardian.app/Contents/MacOS/OCUGuardian")
            child.arguments = ["--broker-guardian"]
            let input = Pipe()
            child.standardInput = input
            let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/OpenComputerUse/LockedUse", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
            let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard logFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            defer { try? log.close() }
            child.standardOutput = log
            child.standardError = FileHandle.nullDevice
            try child.run()
            guardian = child
            try input.fileHandleForWriting.write(contentsOf: LockedUseIPCFrame.encode(LockedUseGuardianBootstrap(leaseID: lease, token: token, startupDeadline: startupDeadline)))
            try input.fileHandleForWriting.close()
            startPolling()
            let deadline = startupDeadline
            while ProcessInfo.processInfo.systemUptime < deadline {
                let status = try connection.request(.init(operation: .status, leaseID: lease, session: .current()))
                receive(status)
                if status.result == .active { recoveryDeadline.cancel(); return }
                if status.result == .denied || status.phase == .relocking || status.phase == .awaitingManualUnlock || !child.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw ComputerUseError.stateUnavailable("Locked Use could not observe a protected GUI session becoming unlocked.")
        } catch { end(); throw error }
    }

    /// Observer-side status for the release-barrier wait; nil when the observer cannot
    /// be reached, which leaves admission entirely to the broker's own barriers.
    private func releasedGuardsStatus() -> (phase: LockedUseStateMachine.Phase?, guardsReleased: Bool?)? {
        guard let observer = try? LockedUseIPCClient(endpoint: .observer,
            brokerRequirement: LockedUseSigningIdentity.brokerRequirement()) else { return nil }
        defer { observer.close() }
        guard let reply = try? observer.request(.init(operation: .status, session: .current())) else { return nil }
        return (reply.phase, reply.guardsReleased)
    }

    private func validateAction() throws {
        mutex.lock(); let connection = broker; let lease = lease; let denied = stopped || clientDisconnected; mutex.unlock()
        guard !denied, let connection, let lease else {
            throw ComputerUseError.stateUnavailable("Locked Use lease is no longer active.")
        }
        let reply = try connection.request(.init(operation: .action, leaseID: lease, session: .current()))
        receive(reply)
        guard reply.result == .active else { throw ComputerUseError.stateUnavailable("Locked Use stopped before this GUI action.") }
    }

    /// Exercise real dual-guard cleanup without allowing a single unlock. The
    /// installed validation Broker rejects this mode in a production profile.
    func validateRecovery() throws -> Bool {
        let session = LockedUseSession.current()
        guard session.state == .locked else { throw ComputerUseError.stateUnavailable("Recovery probe requires a locked session") }
        mutex.lock(); recoveryProbeStarted = false; mutex.unlock()
        do { try acquire(session: session, recoveryProbe: true) }
        catch { logger.notice("recoveryProbeAcquireEnded") }
        mutex.lock(); let started = recoveryProbeStarted; mutex.unlock()
        guard started else { throw ComputerUseError.stateUnavailable("Recovery probe was not admitted") }
        let observer = try LockedUseIPCClient(endpoint: .observer, brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
        defer { observer.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let reply = try observer.request(.init(operation: .status, session: .current()))
            if reply.phase == .awaitingManualUnlock, reply.guardsReleased == true,
               reply.recoveryProbePrepared == true,
               LockedUseSession.current() == session { return true }
            if reply.phase == .awaitingManualUnlock, reply.guardsReleased == true {
                throw ComputerUseError.stateUnavailable("Recovery probe stopped before both guards became ready")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ComputerUseError.stateUnavailable("Recovery probe did not observe both guards released")
    }

    /// A fresh CLI connection still has to report an actual normal unlock.
    /// Wall-clock waiting or merely creating a new client cannot reset the
    /// Broker's failed locked episode.
    func observeManualUnlock() throws -> Bool {
        let session = LockedUseSession.current()
        guard session.state == .unlocked else { return false }
        let observer = try LockedUseIPCClient(endpoint: .observer, brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
        defer { observer.close() }
        let reply = try observer.request(.init(operation: .status, session: session))
        if reply.phase == .idle {
            mutex.lock(); if lease == nil { stopped = false }; mutex.unlock()
        }
        return reply.phase == .idle && reply.guardsReleased == true
    }

    func protectionReleased() throws -> Bool {
        let observer = try LockedUseIPCClient(endpoint: .observer, brokerRequirement: LockedUseSigningIdentity.brokerRequirement())
        defer { observer.close() }
        let reply = try observer.request(.init(operation: .status, session: .current()))
        return reply.guardsReleased == true && (reply.phase == .idle || reply.phase == .awaitingManualUnlock)
    }

    func recordValidation(manual: Bool = false) throws {
        mutex.lock(); let lease = manual ? validationLease : lease; mutex.unlock()
        guard let lease else { throw ComputerUseError.stateUnavailable("No native validation lease.") }
        if manual {
            let connection = try LockedUseIPCClient(endpoint: .agent, brokerRequirement: LockedUseSigningIdentity.brokerRequirement(), clientSocket: clientSocket)
            defer { connection.close() }
            let reply = try connection.request(.init(operation: .validationManual, leaseID: lease, session: .current()))
            guard reply.result != .denied else { throw ComputerUseError.stateUnavailable("Validation manual-unlock confirmation denied.") }
        } else {
            try validateAction()
            mutex.lock(); let connection = broker; mutex.unlock()
            let reply = try connection?.request(.init(operation: .validationPassed, leaseID: lease))
            guard reply?.result != .denied, reply != nil else { throw ComputerUseError.stateUnavailable("Validation evidence denied.") }
            mutex.lock(); validationLease = lease; mutex.unlock()
        }
    }

    func end(disconnecting: Bool = false) {
        mutex.lock()
        stopped = lease != nil
        clientDisconnected = clientDisconnected || disconnecting
        let connection = broker; let lease = lease; let drain = !inFlight
        mutex.unlock()
        if lease != nil { recoveryDeadline.arm(after: 5) }
        if let connection, let lease {
            if let reply = try? connection.request(.init(operation: .end, leaseID: lease, stopReason: disconnecting ? .disconnected : .turnEnded)) { receive(reply) }
            if drain { acknowledgeDrain() }
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ocu.locked-use.connection"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [self] in
            mutex.lock(); let connection = broker; let lease = lease; mutex.unlock()
            guard let lease else { return }
            do {
                let active: LockedUseIPCClient
                if let connection { active = connection }
                else {
                    let candidate = try LockedUseIPCClient(endpoint: .agent, brokerRequirement: LockedUseSigningIdentity.brokerRequirement(), clientSocket: clientSocket)
                    let hello = try candidate.request(.init(operation: .ownerRecoveryHello, leaseID: lease, session: .current()))
                    guard hello.result != .denied else { candidate.close(); throw ComputerUseError.stateUnavailable("Broker recovery denied") }
                    mutex.lock(); broker = candidate; mutex.unlock()
                    active = candidate
                }
                let reply = try active.request(.init(operation: .status, leaseID: lease, session: .current()))
                receive(reply)
                mutex.lock(); let drain = stopped && !inFlight; mutex.unlock()
                if drain { acknowledgeDrain() }
            } catch {
                logger.error("brokerPollingFailed recoveryDeadlineArmed=true")
                recoveryDeadline.arm(after: 5)
                mutex.lock(); stopped = true; let failed = broker; broker = nil; mutex.unlock()
                failed?.close()
                // Guardian independently observes Broker failure and relocks.
                // Do not kill it, its watchdog, or its shields on IPC failure.
            }
        }
        self.timer = timer; timer.resume()
    }

    private func receive(_ reply: LockedUseIPCReply) {
        mutex.lock(); defer { mutex.unlock() }
        if reply.effects.contains("stopActions") || reply.phase == .relocking {
            stopped = true
            recoveryDeadline.arm(after: 5)
        }
        if reply.phase == .idle || reply.phase == .awaitingManualUnlock {
            recoveryDeadline.cancel()
            timer?.cancel(); timer = nil
            // This acknowledgment follows Guardian's lock observation and drain.
            lease = nil
            if reply.phase == .idle { stopped = false }
            // Lock-presentation evidence has formed (idle) or the episode is over
            // (latched): the display no longer needs our protection.
            displayHold?.release(); displayHold = nil
            broker?.close(); broker = nil
        }
    }

    private func acknowledgeDrain() {
        mutex.lock(); let connection = broker; let lease = lease; mutex.unlock()
        guard let connection, let lease else {
            logger.notice("actionDrainDeferred brokerAvailable=\(connection != nil, privacy: .public) leaseAvailable=\(lease != nil, privacy: .public)")
            return
        }
        logger.notice("actionDrainSubmitting")
        do {
            let reply = try connection.request(.init(operation: .quiesced, leaseID: lease))
            logger.notice("actionDrainReply phase=\(reply.phase.rawValue, privacy: .public) denied=\(reply.result == .denied, privacy: .public)")
            receive(reply)
        } catch {
            logger.error("actionDrainRPCFailed recoveryDeadlinePending=true")
        }
    }
}
