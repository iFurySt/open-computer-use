import AppKit
import Darwin
import Foundation
import OpenComputerUseKit

@main
enum OpenComputerUseMain {
    @MainActor
    static func main() {
        do {
            try run()
        } catch let error as OpenComputerUseCLIError {
            writeToStandardError(error.errorDescription ?? error.message)
            exit(EXIT_FAILURE)
        } catch let error as ComputerUseError {
            writeToStandardError(error.errorDescription ?? String(describing: error))
            exit(EXIT_FAILURE)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            writeToStandardError(message)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if MacOSAppAgentProxy.isAgentInvocation(arguments: arguments) {
            try MacOSAppAgentProxy.runAgent(arguments: arguments)
            return
        }

        let command = try parseOpenComputerUseCLI(arguments: arguments)

        if MacOSAppAgentProxy.shouldProxy(command: command) {
            exit(try MacOSAppAgentProxy.runProxy(command: command, arguments: arguments))
        }

        switch command {
        case .lockedUseManagement:
            _ = try LockedUseSettings.handle(arguments: arguments)
        case .mcp:
            let service = ComputerUseService()
            let server = StdioMCPServer(service: service)
            if VisualCursorSupport.isEnabled {
                try MainActor.assumeIsolated {
                    try MCPAppRuntime.run(server: server)
                }
            } else {
                try server.run()
            }
        case let .doctor(json):
            let permissions = PermissionDiagnostics.current()
            print(try json ? permissions.jsonText() : permissions.summary)
            if !json {
                print(LockedUseDiagnostics.current().summary)
            }
            if !json && !permissions.missingPermissions.isEmpty {
                PermissionOnboardingApp.launch()
            }
        case let .lockedUseStatus(json):
            let diagnostics = LockedUseDiagnostics.current()
            print(try json ? diagnostics.jsonText() : diagnostics.summary)
        case .listApps:
            let service = ComputerUseService()
            print(service.listApps().primaryText ?? "")
        case let .snapshot(app, textLimit, treeLimits, observation):
            let service = ComputerUseService()
            print(try service.getAppState(app: app, textLimit: textLimit, treeLimits: treeLimits, observation: observation).textContent)
        case let .call(invocation):
            // No NSApplication here, so no drawn cursor: it would vanish with this
            // process, and playing it inline held every click for its glide.
            let output = try runOpenComputerUseCall(invocation)
            print(try output.jsonText())
            if output.hasToolError {
                exit(EXIT_FAILURE)
            }
        case .turnEnded:
            postOpenComputerUseTurnEndedNotification()
            print("turn-ended acknowledged")
        case let .help(command):
            print(openComputerUseHelpText(command: command))
        case .version:
            print(resolvedOpenComputerUseVersion())
        case .launchOnboarding:
            if !PermissionDiagnostics.current().allGranted {
                PermissionOnboardingApp.launch()
            }
        }
    }

    private static func writeToStandardError(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else {
            return
        }

        FileHandle.standardError.write(data)
    }
}
