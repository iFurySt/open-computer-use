import Darwin
import Dispatch
import Foundation
import LockedUseNative
import OpenComputerUseKit
import os
import Security

@main
enum BrokerMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2,
                  ["--serve", "--serve-validation"].contains(CommandLine.arguments[1]), geteuid() == 0 else {
                throw BrokerError.message("Usage: OCULockService --serve | --serve-validation (administrator installed service only)")
            }
            let approvals = try LockedUseClientApprovals.loadInstalled()
            let configuration = try LockedUseBrokerConfiguration.loadInstalled()
            let validation = CommandLine.arguments[1] == "--serve-validation"
            let team = try LockedUseSigningIdentity.current().teamIdentifier!
            // Administrator enrollment enables the backend; all installed code
            // still has to pass the same-team strict signature verification.
            _ = try LockedUseComponentValidation.current(team: team)
            let server = try BrokerServer(approvals: approvals, enabled: configuration.enabled,
                backendValidated: true, validationMode: validation)
            try server.start()
            withExtendedLifetime(server) { dispatchMain() }
        } catch {
            // Never log bodies, capabilities, AX content or peer credentials.
            fputs("Locked Use Broker startup failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

enum BrokerError: Error { case message(String) }

/// All mutable state lives on this one queue, independent of GUI tool actions.
private final class BrokerServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.opencomputeruse.locked-use", category: "Broker")
    private let queue = DispatchQueue(label: "dev.opencomputeruse.locked-use.broker")
    private let approvals: LockedUseClientApprovals
    private var coordinator: LockedUseBrokerCoordinator
    private var listeners: [DispatchSourceRead] = []
    private var connections: [UUID: BrokerConnection] = [:]
    private let peerAuthenticator = LockedUsePeerAuthenticator()
    private var pendingAdmissions: [UUID: Int32] = [:]
    private var cancelledAdmissions: Set<UUID> = []
    private var forwardedAdmissions: Set<UUID> = []
    private var timer: DispatchSourceTimer?
    private var timerInterval: TimeInterval?
    private var lastPolicyCheck: TimeInterval = 0
    private var policyInvalidated = false
    private let policyMonitor = LockedUsePolicyMonitor {
        try LockedUseAuthorizationRules.installedRulesObserved()
    }
    private var validationReport: LockedUseValidationReport?
    private var lastValidationData: Data?
    private var recoverySeed: LockedUseRecoveryRecord?
    private var ownerClientToken: Data?
    private var lastRecoveryData: Data?
    private let instanceLock: Int32

    init(approvals: LockedUseClientApprovals, enabled: Bool, backendValidated: Bool, validationMode: Bool) throws {
        self.approvals = approvals
        coordinator = .init(enabled: enabled, backendValidated: backendValidated, requiresWatchdog: true, validationMode: validationMode)
        try Self.validateRunDirectory()
        let fd = open("/Library/Application Support/OpenComputerUse/LockedUse/run/broker.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BrokerError.message("instance lock unavailable") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, ocu_has_mutating_acl(fd) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw BrokerError.message("instance already running or insecure lock file")
        }
        instanceLock = fd
        let bootID = try LockedUseComponentValidation.bootSessionID()
        recoverySeed = try LockedUseRecoveryRecord.loadInstalled()
        if let record = recoverySeed, record.bootSessionID != bootID {
            // A kernel reboot destroys the old GUI session and queued native
            // authorization work. A new completed login is a separate epoch.
            guard unlink("/Library/Application Support/OpenComputerUse/LockedUse/lease-recovery.json") == 0 else { throw BrokerError.message("old boot recovery fence unavailable") }
            recoverySeed = nil
        }
        ownerClientToken = recoverySeed?.originalClientToken
        coordinator = .init(enabled: enabled, backendValidated: backendValidated, requiresWatchdog: true, recovery: recoverySeed, bootSessionID: bootID, validationMode: validationMode)
    }

    func start() throws {
        policyMonitor.refresh()
        for endpoint in [LockedUseIPCEndpoint.agent, .guardian, .plugin, .observer, .admin] {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BrokerError.message("socket unavailable") }
            do {
                try Self.removeStaleEndpoint(endpoint.path)
                try LockedUseIPCSocket.configure(fd)
                guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BrokerError.message("nonblocking socket unavailable") }
                var address = try LockedUseIPCSocket.address(path: endpoint.path)
                // Never unlink an unknown/still-running service's socket.
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0, chmod(endpoint.path, 0o666) == 0, listen(fd, 16) == 0 else {
                    throw BrokerError.message("endpoint already exists or cannot be secured")
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.accept(fd: fd, endpoint: endpoint) }
                source.setCancelHandler { Darwin.close(fd) }
                listeners.append(source)
                source.resume()
            } catch { Darwin.close(fd); throw error }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Cadence is selected after the source is assigned below.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let previousPhase = self.coordinator.phase
                defer {
                    self.updateTimerCadence()
                    if previousPhase != self.coordinator.phase {
                        self.logger.notice("phase=\(self.coordinator.phase.rawValue, privacy: .public) stopReason=\(self.coordinator.stopReason?.rawValue ?? "none", privacy: .public)")
                        self.logProtectionLoss()
                    }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.lastPolicyCheck >= 1 {
                    self.policyMonitor.refresh(now: now)
                    self.lastPolicyCheck = now
                }
                try self.checkInstallationPolicy(requireFresh: false)
                for connection in Array(self.connections.values) where connection.endpoint == .agent && connection.clientDescriptor < 0 && now - connection.created > 2 {
                    self.close(connection)
                }
                if let owner = self.coordinator.owner,
                   let connection = self.connections[owner.connectionID], !connection.clientInvalidated, connection.clientDescriptor >= 0, !connection.clientAdmissionPending {
                    do { try self.verifyOriginalClient(connection) }
                    catch {
                        connection.clientInvalidated = true
                        try self.coordinator.disconnected(connection.context)
                    }
                }
                try self.coordinator.tick(now: now)
                try self.coordinator.pollRecordedProcesses { pid in
                    kill(pid, 0) != 0 && errno == ESRCH
                }
                try self.persistRecovery()
                try self.persistValidation()
            }
            catch { self.stopAll() }
        }
        self.timer = timer
        updateTimerCadence()
        timer.resume()
    }

    private func updateTimerCadence() {
        let interval = LockedUseBrokerPolling.interval(phase: coordinator.phase, fullyReleased: coordinator.isFullyReleased)
        guard interval != timerInterval, let timer else { return }
        timerInterval = interval
        // An incoming begin must restore watchdog cadence immediately, rather
        // than waiting for the next idle tick.
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(interval * 1000)), leeway: .milliseconds(10))
    }

    private func accept(fd: Int32, endpoint: LockedUseIPCEndpoint) {
        for _ in 0..<16 {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { return }
            guard connections.count + pendingAdmissions.count < 64 else { Darwin.close(client); continue }
            do {
                try LockedUseIPCSocket.configure(client)
                guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { throw BrokerError.message("client socket unavailable") }
            } catch { Darwin.close(client); continue }
            let admission = UUID()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            pendingAdmissions[admission] = client
            queue.asyncAfter(deadline: .now() + 8) { [self] in
                guard pendingAdmissions[admission] == client else { return }
                cancelledAdmissions.insert(admission)
                // Keep descriptor ownership until the worker returns. Closing
                // now could reuse the fd while the verifier is inspecting it.
                shutdown(client, SHUT_RDWR)
            }
            peerAuthenticator.verify({ [self] in try authenticate(fd: client, endpoint: endpoint) }) { [self] result in
                queue.async { [self] in
                    pendingAdmissions.removeValue(forKey: admission)
                    let cancelled = cancelledAdmissions.remove(admission) != nil
                    guard !cancelled, ProcessInfo.processInfo.systemUptime < deadline,
                          case let .success(identity) = result else {
                        logger.notice("peerRejected endpoint=\(endpoint.rawValue, privacy: .public)")
                        Darwin.close(client)
                        return
                    }
                    admit(fd: client, endpoint: endpoint, identity: identity)
                }
            }
        }
    }

    private func admit(fd: Int32, endpoint: LockedUseIPCEndpoint, identity: LockedUsePeerIdentity) {
        let role: LockedUseBrokerCoordinator.Role = endpoint == .agent ? .agent : endpoint == .guardian ? .guardian : (endpoint == .observer || endpoint == .admin) ? .observer : .plugin
        let old = [coordinator.recordedOwner, coordinator.recordedGuardian, coordinator.recordedWatchdog]
            .compactMap { $0 }.first { $0.role == role && $0.auditToken == identity.auditToken && $0.codeHash == identity.codeDirectoryHash }
        let context = LockedUseBrokerCoordinator.Context(id: old?.id ?? UUID(), role: role,
            userID: identity.userID, auditSessionID: identity.auditSessionID, auditToken: identity.auditToken,
            processID: identity.processID, codeHash: identity.codeDirectoryHash)
        if let previous = connections[context.id] { close(previous) }
        let connection = BrokerConnection(fd: fd, endpoint: endpoint, identity: identity, context: context)
        connections[context.id] = connection
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak connection] in
            guard let connection, !connection.closed else { return }
            self?.read(connection)
        }
        connection.readSource = source
        source.resume()
    }

    private func authenticate(fd: Int32, endpoint: LockedUseIPCEndpoint) throws -> LockedUsePeerIdentity {
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed > 0.25 {
                logger.notice("verificationSlow endpoint=\(endpoint.rawValue, privacy: .public) elapsedMilliseconds=\(Int(elapsed * 1000), privacy: .public)")
            }
        }
        switch endpoint {
        case .agent: return try approvals.verifiedPeer(socket: fd, role: .agent)
        case .guardian: return try approvals.verifiedPeer(socket: fd, role: .guardian)
        case .observer: return try approvals.verifiedPeer(socket: fd, role: .client)
        case .admin:
            guard let team = try LockedUseSigningIdentity.current().teamIdentifier else { throw BrokerError.message("signer unavailable") }
            let requirement = "identifier \"dev.opencomputeruse.locked-use.installer\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            let peer = try LockedUsePeerIdentity.verified(socket: fd, requirement: requirement)
            guard peer.userID == 0, peer.hardenedRuntime, !peer.permitsCodeInjection else { throw BrokerError.message("untrusted installer") }
            return peer
        case .plugin:
            // The privileged authorization host is Apple signed, not signed by our
            // Developer ID team. Never substitute a user-provided requirement.
            let requirement = "anchor apple and (identifier \"com.apple.authorizationhosthelper.arm64\" or identifier \"com.apple.authorizationhosthelper.x86_64\")"
            let peer = try LockedUsePeerIdentity.verified(socket: fd, requirement: requirement)
            guard peer.userID == 0, peer.auditSessionID > 0, !peer.permitsCodeInjection else { throw BrokerError.message("untrusted authorization helper") }
            return peer
        }
    }

    private func read(_ connection: BrokerConnection) {
        if connection.endpoint == .agent && connection.clientDescriptor < 0 {
            let fd = ocu_receive_peer_socket(connection.fd)
            if fd < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return }
            guard fd >= 0 else { close(connection); return }
            do {
                var native = OCUPeerIdentity()
                guard ocu_copy_peer_identity(fd, &native) == 0, native.effective_user_id == connection.identity.userID,
                      native.audit_session_id == connection.identity.auditSessionID else { throw BrokerError.message("client session mismatch") }
                let token = withUnsafeBytes(of: native.audit_token) { Data($0) }
                let borrowed = LockedUseBorrowedSocket(descriptor: fd)
                connection.clientSocket = borrowed
                connection.clientAdmissionPending = true
                connection.readSource?.suspend()
                let admission = UUID()
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                pendingAdmissions[admission] = fd
                forwardedAdmissions.insert(admission)
                queue.asyncAfter(deadline: .now() + 8) { [self, connection] in
                    guard pendingAdmissions[admission] == fd else { return }
                    cancelledAdmissions.insert(admission)
                    close(connection) // Retain borrowed fd until the worker returns.
                }
                peerAuthenticator.verify({ [self] in
                    try borrowed.withDescriptor { try? approvals.verifiedPeer(socket: $0, role: .client) }
                }) { [self, connection] result in
                    queue.async { [self, connection] in
                        pendingAdmissions.removeValue(forKey: admission)
                        forwardedAdmissions.remove(admission)
                        let cancelled = cancelledAdmissions.remove(admission) != nil
                        connection.clientAdmissionPending = false
                        if connection.closed {
                            connection.clientSocket = nil
                            return
                        }
                        connection.readSource?.resume()
                        guard !cancelled, ProcessInfo.processInfo.systemUptime < deadline,
                              case let .success(client) = result,
                              client != nil || coordinator.recordedOwner?.auditToken == connection.identity.auditToken && ownerClientToken == token else {
                            close(connection); return
                        }
                        connection.clientIdentity = client
                        connection.clientAuditToken = token
                    }
                }
            } catch { Darwin.close(fd); close(connection) }
            return
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(connection.fd, &bytes, bytes.count)
        if count < 0, [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return }
        guard count > 0 else { close(connection); return }
        do {
            if connection.endpoint == .observer { logger.notice("observerStage=readStarted") }
            let current = try connection.identity.revalidated(socket: connection.fd)
            if connection.endpoint == .observer { logger.notice("observerStage=verified") }
            guard current.auditToken == connection.identity.auditToken,
                  current.codeDirectoryHash == connection.identity.codeDirectoryHash else { throw BrokerError.message("peer changed") }
            for frame in try connection.decoder.append(Data(bytes.prefix(count))) {
                let request = try JSONDecoder().decode(LockedUseIPCMessage.self, from: frame).validated()
                // Keep the authenticated agent alive to revoke and acknowledge
                // drainage after its original native client has exited.
                if connection.endpoint == .admin && ![LockedUseIPCMessage.Operation.status, .disable].contains(request.operation) { throw BrokerError.message("invalid installer request") }
                if connection.endpoint == .observer && request.operation != .status { throw BrokerError.message("observer cannot mutate") }
                let previousPhase = coordinator.phase
                let reply: LockedUseIPCReply
                do {
                    if [.begin, .beginRecoveryProbe, .beginUnshieldedDiagnostic, .pluginClaim, .pluginConsume].contains(request.operation) { try checkInstallationPolicy() }
                    if connection.endpoint == .agent && [.begin, .beginRecoveryProbe, .action, .validationPassed, .validationManual].contains(request.operation) {
                        do { try verifyOriginalClient(connection) }
                        catch {
                            connection.clientInvalidated = true
                            try coordinator.disconnected(connection.context)
                            throw error
                        }
                    }
                    if connection.endpoint == .observer { logger.notice("observerStage=handling") }
                    reply = try coordinator.handle(request, context: connection.context, now: ProcessInfo.processInfo.systemUptime)
                    if connection.endpoint == .observer { logger.notice("observerStage=handled") }
                } catch {
                    reply = .init(id: request.id, result: .denied, phase: coordinator.phase,
                        detail: "Request denied by Broker policy")
                }
                updateTimerCadence()
                if previousPhase != coordinator.phase {
                    logger.notice("phase=\(self.coordinator.phase.rawValue, privacy: .public) stopReason=\(self.coordinator.stopReason?.rawValue ?? "none", privacy: .public)")
                    logProtectionLoss()
                }
                if request.operation == .pluginClaim, reply.result != .denied {
                    logger.notice("permitIssued maximumLifetimeSeconds=5")
                }
                if [.pluginClaim, .pluginConsume, .pluginFinished].contains(request.operation) {
                    logger.notice("pluginDecision operation=\(request.operation.rawValue, privacy: .public) result=\(reply.result.rawValue, privacy: .public) phase=\(self.coordinator.phase.rawValue, privacy: .public) sessionMatches=\(connection.context.auditSessionID == self.coordinator.owner?.auditSessionID, privacy: .public) auditUserMatches=\(connection.identity.auditUserID == self.coordinator.owner?.userID, privacy: .public)")
                }
                if reply.result == .denied { logger.notice("denied operation=\(request.operation.rawValue, privacy: .public) sessionMatches=\(connection.context.auditSessionID == self.coordinator.owner?.auditSessionID, privacy: .public) auditUserMatches=\(connection.identity.auditUserID == self.coordinator.owner?.userID, privacy: .public)") }
                // Persist before exposing a consumed authorization or active
                // GUI lease. No permit nonce is ever saved or restored.
                if connection.endpoint == .observer { logger.notice("observerStage=persisting") }
                try persistRecovery()
                if connection.endpoint == .observer { logger.notice("observerStage=persisted") }
                if reply.result != .denied, request.operation == .validationPassed, let leaseID = request.leaseID {
                    let team = try LockedUseSigningIdentity.current().teamIdentifier!
                    validationReport = .init(leaseID: leaseID, evidence: try LockedUseComponentValidation.current(team: team), ownerToken: connection.identity.auditToken)
                }
                if reply.result != .denied, request.operation == .validationManual {
                    guard var report = validationReport, report.leaseID == request.leaseID,
                          report.ownerToken == connection.identity.auditToken, report.lockedAndReleased else { throw BrokerError.message("validation owner mismatch") }
                    report.afterManualUnlockPassed = true; validationReport = report
                }
                try persistValidation()
                connection.pending.append(try LockedUseIPCFrame.encode(reply))
                guard connection.pending.count <= 64 * 1024 else { throw LockedUseIPCFrame.Failure.oversized }
            }
            flush(connection)
        } catch { close(connection) }
    }

    private func logProtectionLoss() {
        guard coordinator.stopReason == .guardLost else { return }
        let evidence = coordinator.protectionDiagnostics(now: ProcessInfo.processInfo.systemUptime)
        logger.notice("guardLostEvidence guardianAgeMilliseconds=\(Int(evidence.guardianAge * 1000), privacy: .public) watchdogAgeMilliseconds=\(Int(evidence.watchdogAge * 1000), privacy: .public) watchdogProtected=\(evidence.watchdogProtected, privacy: .public)")
    }

    private func persistRecovery() throws {
        if let context = coordinator.recordedOwner,
           let token = connections[context.id]?.clientAuditToken { ownerClientToken = token }
        let path = "/Library/Application Support/OpenComputerUse/LockedUse/lease-recovery.json"
        if let token = ownerClientToken, let record = coordinator.recoveryRecord(clientToken: token) {
            _ = try record.validated()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            if data == lastRecoveryData { return }
            try LockedUsePrivateRecord.writeInstalled(data, name: "lease-recovery.json")
            lastRecoveryData = data
        } else if lastRecoveryData != nil || recoverySeed != nil {
            if unlink(path) != 0, errno != ENOENT { throw BrokerError.message("recovery fence removal failed") }
            lastRecoveryData = nil; recoverySeed = nil
        } else { return }
        let directory = open("/Library/Application Support/OpenComputerUse/LockedUse", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BrokerError.message("recovery directory unavailable") }
        let synced = fsync(directory); Darwin.close(directory)
        guard synced == 0 else { throw BrokerError.message("recovery directory durability unavailable") }
    }

    private func persistValidation() throws {
        guard var report = validationReport else { return }
        if coordinator.isFullyReleased, [.idle, .awaitingManualUnlock].contains(coordinator.phase),
           coordinator.recordedOwner?.auditToken == report.ownerToken {
            report.lockedAndReleased = true
        }
        validationReport = report
        // A Broker restart loses incomplete proof; it never certifies resumed
        // recovery as a successful fresh unlock test.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        if data == lastValidationData { return }
        try LockedUsePrivateRecord.writeInstalled(data, name: "validation-report.json")
        lastValidationData = data
    }

    private func checkInstallationPolicy(requireFresh: Bool = true) throws {
        guard !policyInvalidated else {
            if requireFresh { throw BrokerError.message("authentication policy invalidated") }
            return
        }
        let observation = policyMonitor.status()
        if observation == .invalid {
            try coordinator.invalidateInstallation()
            policyInvalidated = true
            logger.error("installationPolicyInvalidated")
        } else if observation == .stale {
            try coordinator.suspendForPolicyObservation()
        }
        if requireFresh, observation != .valid {
            throw BrokerError.message("authentication policy observation unavailable")
        }
    }

    private func verifyOriginalClient(_ connection: BrokerConnection) throws {
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed > 0.25 { logger.notice("originalClientVerificationSlow elapsedMilliseconds=\(Int(elapsed * 1000), privacy: .public)") }
        }
        guard !connection.clientInvalidated, let previous = connection.clientIdentity else { throw BrokerError.message("client unavailable") }
        // A retained SCM_RIGHTS descriptor can outlive its originating client.
        // Reject EOF/dead peers before asking Security.framework to resolve a
        // stale audit token. Live peers still require full signature verification.
        guard kill(previous.processID, 0) == 0 || errno == EPERM else { throw BrokerError.message("client exited") }
        var byte: UInt8 = 0
        let peeked = recv(connection.clientDescriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        guard peeked > 0 || (peeked < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno)) else {
            throw BrokerError.message("client disconnected")
        }
        let client = try previous.revalidated(socket: connection.clientDescriptor)
        guard client.auditToken == previous.auditToken,
              client.codeDirectoryHash == previous.codeDirectoryHash else { throw BrokerError.message("client changed") }
    }

    private func flush(_ connection: BrokerConnection) {
        guard !connection.closed else { return }
        while !connection.pending.isEmpty {
            let count = connection.pending.withUnsafeBytes { buffer in
                Darwin.write(connection.fd, buffer.baseAddress, buffer.count)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if connection.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                    source.setEventHandler { [weak self, weak connection] in
                        guard let connection, !connection.closed else { return }
                        self?.flush(connection)
                    }
                    connection.writeSource = source
                    source.resume()
                }
                return
            }
            guard count > 0 else { close(connection); return }
            connection.pending.removeFirst(count)
        }
        connection.writeSource?.cancel()
        connection.writeSource = nil
    }

    private func close(_ connection: BrokerConnection) {
        guard !connection.closed else { return }
        connection.closed = true
        if connection.clientAdmissionPending { connection.readSource?.resume() }
        connection.clientSocket?.close()
        connection.clientSocket = nil
        try? coordinator.disconnected(connection.context)
        try? persistRecovery()
        connection.readSource?.cancel(); connection.writeSource?.cancel()
        shutdown(connection.fd, SHUT_RDWR); Darwin.close(connection.fd)
        connections.removeValue(forKey: connection.context.id)
    }
    private func stopAll() {
        for connection in Array(connections.values) { close(connection) }
        for (admission, fd) in pendingAdmissions {
            cancelledAdmissions.insert(admission)
            if !forwardedAdmissions.contains(admission) { shutdown(fd, SHUT_RDWR) }
        }
    }

    private static func validateRunDirectory() throws {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw BrokerError.message("root directory unavailable") }
        defer { Darwin.close(fd) }
        for component in ["Library", "Application Support", "OpenComputerUse", "LockedUse", "run"] {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BrokerError.message("installer runtime directory missing") }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == 0,
                  info.st_mode & 0o022 == 0, ocu_has_mutating_acl(next) == 0 else {
                Darwin.close(next); throw BrokerError.message("insecure runtime directory")
            }
            Darwin.close(fd); fd = next
        }
    }

    /// The exclusive instance lock prevents this service's restart from racing
    /// another copy. The enclosing path is root owned and not user writable.
    private static func removeStaleEndpoint(_ path: String) throws {
        var before = stat()
        if lstat(path, &before) != 0 {
            guard errno == ENOENT else { throw BrokerError.message("endpoint inspection failed") }
            return
        }
        guard before.st_uid == 0, before.st_mode & S_IFMT == S_IFSOCK else {
            throw BrokerError.message("unknown object at endpoint")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerError.message("endpoint probe unavailable") }
        defer { Darwin.close(fd) }
        try LockedUseIPCSocket.configure(fd)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BrokerError.message("endpoint probe unavailable") }
        var address = try LockedUseIPCSocket.address(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result < 0, errno == ECONNREFUSED else { throw BrokerError.message("endpoint in use") }
        var after = stat()
        guard lstat(path, &after) == 0, after.st_ino == before.st_ino,
              after.st_dev == before.st_dev, after.st_uid == 0,
              after.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
            throw BrokerError.message("endpoint changed during restart")
        }
    }
    deinit { Darwin.close(instanceLock) }
}

private final class BrokerConnection: @unchecked Sendable {
    let fd: Int32
    let endpoint: LockedUseIPCEndpoint
    let identity: LockedUsePeerIdentity
    let context: LockedUseBrokerCoordinator.Context
    var decoder = LockedUseIPCFrame()
    var pending = Data()
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var closed = false
    let created = ProcessInfo.processInfo.systemUptime
    var clientAuditToken: Data?
    var clientInvalidated = false
    var clientAdmissionPending = false
    var clientSocket: LockedUseBorrowedSocket?
    var clientDescriptor: Int32 { clientSocket?.descriptor ?? -1 }
    var clientIdentity: LockedUsePeerIdentity?
    init(fd: Int32, endpoint: LockedUseIPCEndpoint, identity: LockedUsePeerIdentity,
         context: LockedUseBrokerCoordinator.Context) {
        self.fd = fd; self.endpoint = endpoint; self.identity = identity; self.context = context
    }
}
