import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Security

public struct LockedUseSession: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case locked, unlocked, unavailable }
    public let state: State
    public let userID: UInt32?
    public let auditSessionID: UInt32?

    public init(state: State, userID: UInt32?, auditSessionID: UInt32?) {
        self.state = state
        self.userID = userID
        self.auditSessionID = auditSessionID
    }

    public static func current() -> LockedUseSession {
        var sessionID = SecuritySessionId()
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, &sessionID, &attributes) == errSecSuccess,
              attributes.contains(.sessionHasGraphicAccess) else {
            return .init(state: .unavailable, userID: nil, auditSessionID: nil)
        }
        return from(dictionary: CGSessionCopyCurrentDictionary() as? [String: Any], effectiveUserID: geteuid(), securitySessionID: sessionID)
    }

    static func from(dictionary: [String: Any]?, effectiveUserID: UInt32, securitySessionID: UInt32?) -> LockedUseSession {
        guard let dictionary,
              boolean(dictionary[kCGSessionOnConsoleKey as String]) == true,
              boolean(dictionary[kCGSessionLoginDoneKey as String]) == true,
              let uid = unsignedNumber(dictionary[kCGSessionUserIDKey as String]),
              let auditID = securitySessionID, auditID != 0,
              uid == effectiveUserID, uid != 0 else {
            return .init(state: .unavailable, userID: nil, auditSessionID: nil)
        }
        if let observedAuditID = dictionary["kCGSSessionAuditIDKey"], unsignedNumber(observedAuditID) != auditID {
            return .init(state: .unavailable, userID: uid, auditSessionID: nil)
        }
        // SessionGetInfo provides the stable audit-session identity. The documented
        // kCGSessionConsoleSetKey is absent on some current systems; do not invent
        // a default console ID or reject an otherwise completed GUI login.
        // This WindowServer key is undocumented. Its absence in a completed GUI
        // login is the usual unlocked representation; malformed values fail closed.
        let locked: Bool
        if let value = dictionary["CGSSessionScreenIsLocked"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return .init(state: .unavailable, userID: uid, auditSessionID: auditID)
            }
            locked = number.boolValue
        } else {
            locked = false
        }
        return .init(state: locked ? .locked : .unlocked, userID: uid, auditSessionID: auditID)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func unsignedNumber(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(UInt32.max), value.rounded(.towardZero) == value else { return nil }
        return UInt32(value)
    }
}

public struct LockedUseDiagnostics: Codable, Sendable {
    public let schemaVersion: Int
    public let stage: String
    public let enabled: Bool
    public let available: Bool
    public let clientApproved: Bool
    public let authenticationPolicyIntact: Bool
    public let session: LockedUseSession
    public let accessibility: Bool
    public let screenRecording: Bool
    public let inputMonitoring: Bool
    public let installedPluginVersion: String?
    public let bundledPluginVersion: String?
    public let pluginInstalled: Bool
    public let brokerInstalled: Bool
    public let guardianAccessibility: Bool?
    public let guardianInputMonitoring: Bool?
    public let otherAuthorizationPlugins: [String]
    public let blockers: [String]

    /// Never enables the experimental backend from environment variables, files
    /// written by the user, or the presence of another vendor's authorization plugin.
    public static func current() -> LockedUseDiagnostics {
        let pluginsPath = "/Library/Security/SecurityAgentPlugins"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: pluginsPath)) ?? []
        let ownPlugin = "OCULockAuth.bundle"
        let others = entries.filter { $0.hasSuffix(".bundle") && $0 != ownPlugin && $0 != "OCULockProbe.bundle" }.sorted()
        let configuration = try? LockedUseBrokerConfiguration.loadInstalled()
        let policyIntact = (try? LockedUseAuthorizationRules.installedRulesObserved()) == true
        let identity = try? LockedUseSigningIdentity.current()
        let approvals = try? LockedUseClientApprovals.loadInstalled()
        let approved = approvals?.approvals.contains { record in
            record.role == .agent && record.userID == identity?.userID
                && record.signingIdentifier == identity?.signingIdentifier
                && record.teamIdentifier == identity?.teamIdentifier
        } ?? false
        var available = false
        var guardianPermissions: [String: Bool] = [:]
        if let configuration, let team = try? LockedUseSigningIdentity.current().teamIdentifier,
           let evidence = try? LockedUseComponentValidation.current(team: team) {
            _ = evidence
            guardianPermissions = installedGuardianPermissions()
            available = configuration.enabled && policyIntact && approved
                && AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
                && guardianPermissions["accessibility"] == true && guardianPermissions["inputMonitoring"] == true
        }
        return .init(
            schemaVersion: 1, stage: available ? "enabled" : configuration == nil ? "not-installed" : "unavailable", enabled: configuration?.enabled ?? false, available: available,
            clientApproved: approved, authenticationPolicyIntact: policyIntact,
            session: .current(), accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess(), inputMonitoring: CGPreflightListenEventAccess(),
            installedPluginVersion: Bundle(url: URL(fileURLWithPath: pluginsPath + "/" + ownPlugin))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundledPluginVersion: Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/LockedUse/OCULockAuth.bundle"))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            pluginInstalled: entries.contains(ownPlugin),
            brokerInstalled: FileManager.default.fileExists(atPath: "/Library/Application Support/OpenComputerUse/LockedUse/OCULockService"),
            guardianAccessibility: guardianPermissions["accessibility"],
            guardianInputMonitoring: guardianPermissions["inputMonitoring"],
            otherAuthorizationPlugins: others,
            blockers: available ? [] : [
                "Run ocu locked-use enable and complete permissions for Open Computer Use and OCU Guardian. Installation, client approval, signed components and authentication policy must be intact."
            ]
        )
    }

    private static func installedGuardianPermissions() -> [String: Bool] {
        // Called only after strict installed-component signature verification.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/Application Support/OpenComputerUse/LockedUse/OCU Guardian.app/Contents/MacOS/OCUGuardian")
        process.arguments = ["--permission-status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date().isBefore(deadline) { Thread.sleep(forTimeInterval: 0.01) }
            guard !process.isRunning, process.terminationStatus == 0 else {
                if process.isRunning { process.terminate() }
                return [:]
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard data.count < 8192, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["event"] as? String == "permissionStatus",
                  let accessibility = value["accessibility"] as? Bool,
                  let input = value["inputMonitoring"] as? Bool else { return [:] }
            return ["accessibility": accessibility, "inputMonitoring": input]
        } catch { return [:] }
    }

    public static func versionAdvice(installed: String?, bundled: String?) -> String? {
        guard let installed, let bundled, !installed.isEmpty, !bundled.isEmpty, installed != bundled else { return nil }
        return "Installed Locked Use components differ from this OCU app. Updating OCU does not update system components. Run ocu locked-use disable, then ocu locked-use enable to reinstall; incomplete tasks must finish recovery first."
    }

    public var summary: String {
        "Locked Use: stage=\(stage), enabled=\(enabled), available=\(available), session=\(session.state.rawValue)\n"
            + "Client approved: \(clientApproved), authentication policy intact: \(authenticationPolicyIntact)\n"
            + "Open Computer Use: Accessibility=\(accessibility), Screen Recording=\(screenRecording)\n"
            + "Guardian: Accessibility=\(guardianAccessibility.map(String.init) ?? "unknown"), Input Monitoring=\(guardianInputMonitoring.map(String.init) ?? "unknown")\n"
            + "Authorization plugin: installed=\(installedPluginVersion ?? "unknown"), bundled=\(bundledPluginVersion ?? "unknown")\n"
            + (Self.versionAdvice(installed: installedPluginVersion, bundled: bundledPluginVersion).map { $0 + "\n" } ?? "")
            + "Other authorization plugins: \(otherAuthorizationPlugins.isEmpty ? "none detected" : otherAuthorizationPlugins.joined(separator: ", "))\n"
            + blockers.joined(separator: "\n")
    }

    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Used by fresh snapshots and cached real-app snapshots. Fixture state is not a
/// desktop and remains usable in headless CI. Inventory never triggers unlocking.
func requireUsableComputerUseSession(_ session: LockedUseSession = .current()) throws {
    switch session.state {
    case .unlocked:
        try LockedUseActionScope.validate()
        return
    case .locked:
        throw ComputerUseError.stateUnavailable("The Mac is locked and this GUI request has no active Locked Use lease. Enable and validate Locked Use in the signed app, or unlock normally; run `ocu locked-use status --json` for diagnostics.")
    case .unavailable:
        throw ComputerUseError.stateUnavailable("No completed GUI session for the current console user is available. Computer Use cannot operate a login, switched-user, or unknown session.")
    }
}
