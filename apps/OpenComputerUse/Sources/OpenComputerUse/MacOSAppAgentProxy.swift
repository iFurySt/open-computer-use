import AppKit
import Darwin
import Foundation
import OpenComputerUseKit

private let appAgentCommand = "__open-computer-use-app-agent"
private let appAgentDisableEnvironmentKey = "OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY"
private let appAgentProcessStartDate = Date()
private let appAgentBuildIdentifier = Bundle.main.object(forInfoDictionaryKey: "OpenComputerUseBuildIdentifier") as? String ?? ""

enum MacOSAppAgentProxy {
    static func isAgentInvocation(arguments: [String]) -> Bool {
        arguments.first == appAgentCommand
    }

    @MainActor
    static func runAgent(arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw OpenComputerUseCLIError(message: "\(appAgentCommand) requires a socket path")
        }

        // Swift globals initialize lazily. Capture both before the first request
        // so a later agentInfo call cannot mistake an old process for a rebuild.
        _ = appAgentProcessStartDate
        _ = appAgentBuildIdentifier
        try MacOSAppAgentRuntime.run(socketPath: arguments[1])
    }

    static func shouldProxy(command: OpenComputerUseCLICommand) -> Bool {
        shouldUseMacOSAppAgentProxy(
            command: command,
            proxyDisabled: proxyDisabled,
            appBundleAvailable: PermissionSupport.currentAppBundleURL() != nil,
            runningFromLaunchServicesAppInstance: isRunningFromLaunchServicesAppInstance
        )
    }

    @MainActor
    static func runProxy(command: OpenComputerUseCLICommand, arguments: [String]) throws -> Int32 {
        let socketPath = defaultSocketPath()
        let client = try connectOrLaunchAgent(socketPath: socketPath)

        switch command {
        case .mcp:
            try proxyMCP(client: client)
            return EXIT_SUCCESS
        default:
            let response = try sendCLIRequest(arguments: arguments, client: client)
            if !response.stdout.isEmpty {
                FileHandle.standardOutput.write(Data(response.stdout.utf8))
            }
            if !response.stderr.isEmpty {
                FileHandle.standardError.write(Data(response.stderr.utf8))
            }
            return response.exitCode
        }
    }

    private static var proxyDisabled: Bool {
        let value = ProcessInfo.processInfo.environment[appAgentDisableEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private static var isRunningFromOpenComputerUseAppBundle: Bool {
        Bundle.main.bundleURL.standardizedFileURL.pathExtension == "app"
            && PermissionSupport.isOpenComputerUseBundleIdentifier(Bundle.main.bundleIdentifier)
    }

    private static var isRunningFromLaunchServicesAppInstance: Bool {
        isRunningFromOpenComputerUseAppBundle && getppid() == 1
    }

    private static func defaultSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                openComputerUseAppAgentSocketFileName(
                    namespace: ProcessInfo.processInfo.environment[openComputerUseAppAgentSocketNamespaceEnvironmentKey]
                )
            )
            .standardizedFileURL
            .path
    }

    @MainActor
    private static func connectOrLaunchAgent(socketPath: String) throws -> AppAgentSocketClient {
        guard let appURL = PermissionSupport.currentAppBundleURL() else {
            throw OpenComputerUseCLIError(message: "Unable to locate Open Computer Use.app for app-scoped macOS permissions.")
        }

        if let client = AppAgentSocketClient.connect(path: socketPath) {
            if (try? client.isCurrentAgent(for: appURL)) == true {
                return client
            }

            _ = try? client.request(["kind": "terminate"])
            guard client.waitForDisconnect() else {
                throw OpenComputerUseCLIError(message: "Previous app agent has not exited. Retry after its current work stops.")
            }
            unlink(socketPath)
        } else {
            unlink(socketPath)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [appAgentCommand, socketPath]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let client = AppAgentSocketClient.connect(path: socketPath) {
                return client
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw OpenComputerUseCLIError(message: "Timed out waiting for Open Computer Use.app agent to start.")
    }

    private static func proxyMCP(client: AppAgentSocketClient) throws {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // No run loop drains this thread's autorelease pool either: one per request.
            try autoreleasepool {
                let response = try client.request([
                    "kind": "mcp",
                    "line": line,
                    "environment": proxiedEnvironment(),
                ])

                if let responseLine = response["response"] as? String {
                    FileHandle.standardOutput.write(Data((responseLine + "\n").utf8))
                }
            }
        }
    }

    private static func sendCLIRequest(arguments: [String], client: AppAgentSocketClient) throws -> CLIProxyResponse {
        let response = try client.request([
            "kind": "cli",
            "arguments": resolvingOpenComputerUseCallFilePaths(arguments),
            "environment": proxiedEnvironment(),
        ])

        return CLIProxyResponse(
            stdout: response["stdout"] as? String ?? "",
            stderr: response["stderr"] as? String ?? "",
            exitCode: Int32(response["exitCode"] as? Int ?? 1)
        )
    }

    private static func proxiedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            key.hasPrefix("OPEN_COMPUTER_USE_")
        }
        if let url = try? OCUConfiguration.fileURL(environment: OCUConfiguration.environment) {
            environment["OPEN_COMPUTER_USE_CONFIG_FILE"] = url.path
        }
        return environment
    }
}

private struct CLIProxyResponse {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

@MainActor
private final class MacOSAppAgentRuntime: NSObject, NSApplicationDelegate {
    private let socketPath: String
    private var listener: AppAgentSocketListener?
    private var turnEndedObserver: NSObjectProtocol?

    private init(socketPath: String) {
        self.socketPath = socketPath
    }

    static func run(socketPath: String) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let delegate = MacOSAppAgentRuntime(socketPath: socketPath)
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        turnEndedObserver = DistributedNotificationCenter.default().addObserver(
            forName: openComputerUseTurnEndedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                resetOpenComputerUseBackgroundWindowState()
                resetOpenComputerUseVisualCursor()
            }
        }

        do {
            let listener = try AppAgentSocketListener(path: socketPath)
            self.listener = listener
            listener.start()
        } catch {
            writeAgentError(error)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        resetOpenComputerUseBackgroundWindowState()
        if let turnEndedObserver {
            DistributedNotificationCenter.default().removeObserver(turnEndedObserver)
        }
        listener?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func writeAgentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private final class AppAgentSocketListener: @unchecked Sendable {
    private let path: String
    private let socketFD: Int32
    private var running = true

    init(path: String) throws {
        self.path = path
        unlink(path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        try withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            try pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else {
                    throw OpenComputerUseCLIError(message: "Socket path is too long: \(path)")
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[bytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            close(socketFD)
            unlink(path)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func start() {
        Thread.detachNewThread {
            self.acceptLoop()
        }
    }

    func stop() {
        running = false
        close(socketFD)
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if running {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continue
            }

            Thread.detachNewThread {
                AppAgentConnection(fileDescriptor: clientFD).run()
            }
        }
    }
}

private final class AppAgentConnection: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let server = StdioMCPServer()
    private let lockedUse: LockedUseConnection
    private var keychainProbe: LockedUseKeychainProbe?

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        lockedUse = LockedUseConnection(clientSocket: fileDescriptor)
    }

    func run() {
        guard let file = fdopen(fileDescriptor, "r+") else {
            close(fileDescriptor)
            return
        }
        let monitorQueue = DispatchQueue(label: "ocu.client-disconnect")
        let monitor = DispatchSource.makeTimerSource(queue: monitorQueue)
        // Polls only while a request runs (rescheduled below): between requests the blocking
        // read sees the hang-up itself, and an idle client cost 10 wakeups a second.
        monitor.schedule(deadline: .distantFuture)
        monitor.setEventHandler { [self] in
            var byte: UInt8 = 0
            let count = recv(fileDescriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 || count < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) {
                lockedUse.end(disconnecting: true)
                monitor.cancel()
            }
        }
        monitor.resume()
        defer {
            monitor.cancel(); monitorQueue.sync {}
            lockedUse.end(disconnecting: true)
            if let probe = keychainProbe { keychainProbe = nil; LockedUseDeferredCleanup.shared.retainIfNeeded(probe) }
            server.endSession()
            fclose(file)
        }

        while let line = readAgentLine(file) {
            // A pool per request: this thread's own drains only when the client disconnects.
            autoreleasepool {
                monitor.schedule(deadline: .now(), repeating: .milliseconds(100))
                let response = handle(requestLine: line)
                writeAgentLine(response, to: file)
                // A slow reader can also block the response write. Keep disconnect
                // monitoring active until the whole exchange has finished.
                monitor.schedule(deadline: .distantFuture)
            }
        }
    }

    private func handle(requestLine: String) -> [String: Any] {
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any],
                  let kind = request["kind"] as? String
            else {
                return ["error": "Invalid app-agent request"]
            }

            switch kind {
            case "agentInfo":
                return [
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                    "bundleURL": Bundle.main.bundleURL.standardizedFileURL.path,
                    "executableURL": Bundle.main.executableURL?.standardizedFileURL.path ?? "",
                    "processStartTime": appAgentProcessStartDate.timeIntervalSince1970,
                    "buildIdentifier": appAgentBuildIdentifier,
                ]
            case "terminate":
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
                return ["ok": true]
            case "mcp":
                let line = request["line"] as? String ?? ""
                let environment = request["environment"] as? [String: String] ?? [:]
                let response: String? = try AppAgentEnvironment.withOverrides(environment) {
                    let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    if payload?["method"] as? String == "notifications/turn-ended" { lockedUse.end() }
                    if let method = payload?["method"] as? String, method.hasPrefix("ocu/locked-use/keychain/") || ["ocu/locked-use/validate", "ocu/locked-use/validate-unlocked", "ocu/locked-use/validate-recovery", "ocu/locked-use/validate-unlock", "ocu/locked-use/ready", "ocu/locked-use/protection-released"].contains(method) {
                        var passed = false
                        switch method {
                        case "ocu/locked-use/ready":
                            passed = try lockedUse.observeManualUnlock()
                        case "ocu/locked-use/protection-released":
                            passed = try lockedUse.protectionReleased()
                        case "ocu/locked-use/validate-recovery":
                            passed = try lockedUse.validateRecovery()
                        case "ocu/locked-use/validate-unlock":
                            guard LockedUseSession.current().state == .locked else {
                                throw ComputerUseError.stateUnavailable("Begin unlock validation in a locked session")
                            }
                            // acquire() returns only after Root has observed
                            // the original session unlocked with fresh guards.
                            // No application, input, capture or Keychain access.
                            try lockedUse.perform {
                                guard LockedUseSession.current().state == .unlocked else {
                                    throw ComputerUseError.stateUnavailable("Protected session did not remain unlocked")
                                }
                            }
                            passed = true
                        case "ocu/locked-use/keychain/prepare", "ocu/locked-use/keychain/prepare-legacy":
                            guard LockedUseSession.current().state == .unlocked, keychainProbe == nil else { throw ComputerUseError.stateUnavailable("Prepare validation items in a normally unlocked session.") }
                            keychainProbe = try LockedUseKeychainProbe(includeDataProtection: method != "ocu/locked-use/keychain/prepare-legacy"); passed = true
                        case "ocu/locked-use/keychain/verify":
                            guard let probe = keychainProbe else { throw ComputerUseError.stateUnavailable("Prepare validation items first.") }
                            try lockedUse.perform { try probe.verify() }; passed = true
                        case "ocu/locked-use/validate-unlocked":
                            guard LockedUseSession.current().state == .unlocked, let probe = keychainProbe else {
                                throw ComputerUseError.stateUnavailable("Unshielded native fixture preflight requires a normally unlocked session.")
                            }
                            try lockedUse.perform { try LockedUseNativeValidation.run(probe: probe) }
                            passed = true
                        case "ocu/locked-use/validate":
                            guard LockedUseSession.current().state == .locked, let probe = keychainProbe else {
                                throw ComputerUseError.stateUnavailable("Begin fixed native validation from a locked session with prepared isolated Keychain items.")
                            }
                            try lockedUse.perform {
                                try LockedUseNativeValidation.run(probe: probe)
                                if probe.includesDataProtection { try lockedUse.recordValidation() }
                            }
                            passed = true
                        case "ocu/locked-use/keychain/verify-manual":
                            guard LockedUseSession.current().state == .unlocked, let probe = keychainProbe else {
                                throw ComputerUseError.stateUnavailable("Unlock normally before the final isolated Keychain check.")
                            }
                            try probe.verify()
                            if probe.includesDataProtection { try lockedUse.recordValidation(manual: true) }
                            passed = true
                        case "ocu/locked-use/keychain/cleanup":
                            passed = keychainProbe?.cleanup() ?? true
                            if passed { keychainProbe = nil }
                        default: throw ComputerUseError.message("Unknown Keychain validation operation.")
                        }
                        let result: [String: Any] = ["jsonrpc": "2.0", "id": payload?["id"] ?? NSNull(), "result": ["passed": passed, "existingItemsRead": false, "dataProtectionIncluded": keychainProbe?.includesDataProtection ?? false]]
                        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                    }
                    let parameters = payload?["params"] as? [String: Any]
                    if payload?["method"] as? String == "tools/call",
                       let name = parameters?["name"] as? String,
                       name != "list_apps", ToolDefinitions.all.contains(where: { $0.name == name }) {
                        return try lockedUse.perform { server.handle(line: line) }
                    }
                    return server.handle(line: line)
                }
                if let response {
                    return ["response": response]
                }
                return ["response": NSNull()]
            case "cli":
                let arguments = request["arguments"] as? [String] ?? []
                let environment = request["environment"] as? [String: String] ?? [:]
                let response = try AppAgentEnvironment.withOverrides(environment) {
                    let command = try parseOpenComputerUseCLI(arguments: arguments)
                    switch command {
                    case .snapshot, .call:
                        return try lockedUse.perform { runCLI(arguments: arguments) }
                    default: return runCLI(arguments: arguments)
                    }
                }
                return [
                    "stdout": response.stdout,
                    "stderr": response.stderr,
                    "exitCode": Int(response.exitCode),
                ]
            default:
                return ["error": "Unknown app-agent request kind: \(kind)"]
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // Preserve the native RPC id even when lease acquisition fails
            // before the MCP server runs. The stdio proxy forwards responses,
            // not the app-agent envelope's error field.
            if let envelope = try? JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any] {
                if envelope["kind"] as? String == "mcp",
                   let line = envelope["line"] as? String,
                   let rpc = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = rpc["id"] {
                    let failure: [String: Any] = ["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32000, "message": message]]
                    if let data = try? JSONSerialization.data(withJSONObject: failure) {
                        return ["response": String(decoding: data, as: UTF8.self)]
                    }
                }
                if envelope["kind"] as? String == "cli" {
                    return ["stdout": "", "stderr": message + "\n", "exitCode": Int(EXIT_FAILURE)]
                }
            }
            return ["error": message]
        }
    }

    private func runCLI(arguments: [String]) -> CLIProxyResponse {
        do {
            let command = try parseOpenComputerUseCLI(arguments: arguments)

            switch command {
            case .launchOnboarding:
                let permissions = PermissionDiagnostics.current()
                if !permissions.allGranted {
                    Task { @MainActor in
                        PermissionOnboardingApp.present()
                    }
                }
                return CLIProxyResponse(stdout: "", stderr: "", exitCode: EXIT_SUCCESS)

            case let .doctor(json):
                let permissions = PermissionDiagnostics.current()
                if !json && !permissions.missingPermissions.isEmpty {
                    Task { @MainActor in
                        PermissionOnboardingApp.present()
                    }
                }
                let text = try json ? permissions.jsonText() : permissions.summary + "\n" + LockedUseDiagnostics.current().summary
                return CLIProxyResponse(stdout: text + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .lockedUseStatus(json):
                let diagnostics = LockedUseDiagnostics.current()
                return CLIProxyResponse(stdout: (try json ? diagnostics.jsonText() : diagnostics.summary) + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case .listApps:
                let service = ComputerUseService()
                return CLIProxyResponse(stdout: (service.listApps().primaryText ?? "") + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .snapshot(app, textLimit, treeLimits, observation):
                let service = ComputerUseService()
                let text = try service.getAppState(app: app, textLimit: textLimit, treeLimits: treeLimits, observation: observation).textContent
                return CLIProxyResponse(stdout: text + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .call(invocation):
                let output = try runOpenComputerUseCall(invocation)
                return CLIProxyResponse(
                    stdout: try output.jsonText() + "\n",
                    stderr: "",
                    exitCode: output.hasToolError ? EXIT_FAILURE : EXIT_SUCCESS
                )

            default:
                return CLIProxyResponse(stdout: "", stderr: "Unsupported proxied command.\n", exitCode: EXIT_FAILURE)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return CLIProxyResponse(stdout: "", stderr: message + "\n", exitCode: EXIT_FAILURE)
        }
    }
}

private enum AppAgentEnvironment {
    private static let lock = NSLock()

    static func withOverrides<T>(_ overrides: [String: String], _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }

        let keys = Set(overrides.keys).union(OCUConfiguration.environmentKeys)
        let previousValues = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        for key in OCUConfiguration.environmentKeys where overrides[key] == nil { unsetenv(key) }
        for (key, value) in overrides {
            setenv(key, value, 1)
        }

        defer {
            for (key, previousValue) in previousValues {
                if let previousValue {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        return try body()
    }
}

private final class AppAgentSocketClient: @unchecked Sendable {
    private let file: UnsafeMutablePointer<FILE>

    private init(file: UnsafeMutablePointer<FILE>) {
        self.file = file
    }

    deinit {
        fclose(file)
    }

    static func connect(path: String) -> AppAgentSocketClient? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer -> Bool in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else {
                    return false
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[bytes.count] = 0
                return true
            }
        }

        guard copied else {
            close(fd)
            return nil
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, let file = fdopen(fd, "r+") else {
            close(fd)
            return nil
        }

        return AppAgentSocketClient(file: file)
    }

    func request(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let line = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode app-agent request.")
        }

        writeAgentLine(line, to: file)

        guard let responseLine = readAgentLine(file),
              let response = try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any]
        else {
            throw ComputerUseError.message("Open Computer Use.app agent closed the connection.")
        }

        if let error = response["error"] as? String {
            throw ComputerUseError.message(error)
        }

        return response
    }

    func waitForDisconnect() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var byte: UInt8 = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = recv(fileno(file), &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 { return true }
            if count < 0, ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func isCurrentAgent(for appURL: URL) throws -> Bool {
        let response = try request(["kind": "agentInfo"])
        let expectedBundleURL = appURL.standardizedFileURL

        guard response["bundleURL"] as? String == expectedBundleURL.path else {
            return false
        }

        if let expectedBuild = Bundle(url: expectedBundleURL)?.object(forInfoDictionaryKey: "OpenComputerUseBuildIdentifier") as? String,
           !expectedBuild.isEmpty, response["buildIdentifier"] as? String != expectedBuild { return false }

        guard let processStartTime = response["processStartTime"] as? TimeInterval else {
            return false
        }

        guard let executableURL = executableURL(for: expectedBundleURL),
              let modifiedAt = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else {
            return true
        }

        return processStartTime + 0.5 >= modifiedAt.timeIntervalSince1970
    }

    private func executableURL(for appURL: URL) -> URL? {
        guard let bundle = Bundle(url: appURL),
              let executableName = bundle.object(forInfoDictionaryKey: kCFBundleExecutableKey as String) as? String,
              !executableName.isEmpty
        else {
            return nil
        }

        return appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
            .standardizedFileURL
    }
}

private func readAgentLine(_ file: UnsafeMutablePointer<FILE>) -> String? {
    var bytes: [UInt8] = []

    while true {
        let character = fgetc(file)
        if character == EOF {
            return bytes.isEmpty ? nil : String(data: Data(bytes), encoding: .utf8)
        }
        if character == 10 {
            return String(data: Data(bytes), encoding: .utf8)
        }
        bytes.append(UInt8(character))
    }
}

private func writeAgentLine(_ object: [String: Any], to file: UnsafeMutablePointer<FILE>) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
       let line = String(data: data, encoding: .utf8)
    {
        writeAgentLine(line, to: file)
    }
}

private func writeAgentLine(_ line: String, to file: UnsafeMutablePointer<FILE>) {
    let output = line + "\n"
    _ = output.withCString { pointer in
        fputs(pointer, file)
    }
    fflush(file)
}
