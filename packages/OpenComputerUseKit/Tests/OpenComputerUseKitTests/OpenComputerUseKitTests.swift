import AppKit
import ImageIO
import XCTest
@testable import OpenComputerUseKit

final class OpenComputerUseKitTests: XCTestCase {
    func testAppAgentSocketFileNamePreservesLegacyDefault() {
        XCTAssertEqual(openComputerUseAppAgentSocketFileName(namespace: nil), "open-computer-use-agent.sock")
        XCTAssertEqual(openComputerUseAppAgentSocketFileName(namespace: "   "), "open-computer-use-agent.sock")
    }

    func testAppAgentSocketFileNameIsDeterministicAndNamespaced() {
        let first = openComputerUseAppAgentSocketFileName(namespace: "boss-resume:profile-a")
        let second = openComputerUseAppAgentSocketFileName(namespace: "boss-resume:profile-b")

        XCTAssertEqual(first, openComputerUseAppAgentSocketFileName(namespace: "boss-resume:profile-a"))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("open-computer-use-agent-"))
        XCTAssertTrue(first.hasSuffix(".sock"))
        XCTAssertLessThan(first.count, 80)
    }

    func testCLIRecognizesGlobalHelpAndVersionFlags() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["-h"]), .help(command: nil))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["--help"]), .help(command: nil))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["-v"]), .version)
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["--version"]), .version)
    }

    func testDoctorJSONContract() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["doctor"]), .doctor())
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["doctor", "--json"]), .doctor(json: true))
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["doctor", "--json", "--json"]))
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["doctor", "--unknown"]))
        XCTAssertTrue(shouldUseMacOSAppAgentProxy(
            command: .doctor(json: true), proxyDisabled: false,
            appBundleAvailable: true, runningFromLaunchServicesAppInstance: false
        ))
        for accessibility in [false, true] {
            for screenCapture in [false, true] {
                let diagnostics = PermissionDiagnostics(
                    accessibilityTrusted: accessibility, screenCaptureGranted: screenCapture
                )
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(try diagnostics.jsonText().utf8)
                ) as? [String: Any])
                XCTAssertEqual(payload["platform"] as? String, "macos")
                XCTAssertEqual(payload["accessibilityTrusted"] as? Bool, accessibility)
                XCTAssertEqual(payload["screenCaptureGranted"] as? Bool, screenCapture)
                XCTAssertEqual(payload["allGranted"] as? Bool, accessibility && screenCapture)
                XCTAssertEqual(payload["missingPermissions"] as? [String],
                               diagnostics.missingPermissions.map(\.rawValue))
            }
        }
    }

    func testCLIRecognizesCommandSpecificHelp() throws {
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["help", "snapshot"]), .help(command: "snapshot"))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["snapshot", "--help"]), .help(command: "snapshot"))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["doctor", "-h"]), .help(command: "doctor"))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["call", "--help"]), .help(command: "call"))
    }

    func testCLIRecognizesSingleToolCallCommand() throws {
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["call", "list_apps"]),
            .call(.single(toolName: "list_apps", argumentsJSON: nil, argumentsFile: nil))
        )

        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["call", "get_app_state", "--args", #"{"app":"TextEdit"}"#]),
            .call(.single(toolName: "get_app_state", argumentsJSON: #"{"app":"TextEdit"}"#, argumentsFile: nil))
        )
    }

    func testCLIRecognizesJSONSequenceCallCommand() throws {
        let calls = #"[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]"#

        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["call", "--calls", calls]),
            .call(.sequence(
                callsJSON: calls,
                callsFile: nil,
                interCallDelay: openComputerUseDefaultInterCallDelay
            ))
        )
    }

    func testCLIRecognizesJSONSequenceCallCommandWithCustomSleep() throws {
        let calls = #"[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]"#

        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["call", "--calls", calls, "--sleep", "0.5"]),
            .call(.sequence(callsJSON: calls, callsFile: nil, interCallDelay: 0.5))
        )
    }

    func testCLIRecognizesTurnEndedNotifyPayload() throws {
        let payload = #"{"type":"agent-turn-complete","turn-id":"12345"}"#

        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["turn-ended"]), .turnEnded(payload: nil))
        XCTAssertEqual(try parseOpenComputerUseCLI(arguments: ["turn-ended", payload]), .turnEnded(payload: payload))
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["turn-ended", "--previous-notify", #"["/bin/true"]"#, payload]),
            .turnEnded(payload: payload)
        )
    }

    func testCLIRequiresSnapshotArgument() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(
                    message: "snapshot requires an app name or bundle identifier",
                    helpCommand: "snapshot"
                )
            )
        }
    }

    func testCLIRecognizesSnapshotTextLimitFlag() throws {
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit"]),
            .snapshot(app: "TextEdit")
        )
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["snapshot", "--text-limit", "1000", "TextEdit"]),
            .snapshot(app: "TextEdit", textLimit: SnapshotTextLimit(maxCount: 1000))
        )
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["snapshot", "TextEdit", "--text-limit", "max"]),
            .snapshot(app: "TextEdit", textLimit: .max)
        )
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["snapshot", "--max-tree-nodes", "3000", "--max-tree-depth", "96", "TextEdit"]),
            .snapshot(
                app: "TextEdit",
                treeLimits: AccessibilityTreeLimits(maxNodeCount: 3000, maxDepth: 96)
            )
        )
        XCTAssertEqual(
            try parseOpenComputerUseCLI(arguments: ["snapshot", "--max-tree-nodes", "3000", "TextEdit"]),
            .snapshot(
                app: "TextEdit",
                treeLimits: AccessibilityTreeLimits(maxNodeCount: 3000, maxDepth: accessibilityTreeMaxDepth)
            )
        )
    }

    func testCLIRejectsOldSnapshotFullTextFlag() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "--show-full-text", "TextEdit"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(message: "Unknown snapshot option: --show-full-text", helpCommand: "snapshot")
            )
        }
    }

    func testCLIRejectsInvalidSnapshotTextLimit() {
        for value in ["0", "-1", "1.5", "full"] {
            XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "--text-limit", value, "TextEdit"])) { error in
                XCTAssertEqual(
                    error as? OpenComputerUseCLIError,
                    OpenComputerUseCLIError(message: "--text-limit must be a positive integer or max", helpCommand: "snapshot")
                )
            }
        }
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "--text-limit"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(message: "--text-limit requires a positive integer or max value", helpCommand: "snapshot")
            )
        }
    }

    func testCLIRejectsInvalidSnapshotTreeBudget() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "--max-tree-nodes", "0", "TextEdit"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(message: "--max-tree-nodes must be a positive integer", helpCommand: "snapshot")
            )
        }
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "--max-tree-depth", "1.5", "TextEdit"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(message: "--max-tree-depth must be a positive integer", helpCommand: "snapshot")
            )
        }
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["snapshot", "--max-tree-nodes"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(message: "--max-tree-nodes requires a positive integer value", helpCommand: "snapshot")
            )
        }
    }

    func testCLIRejectsMixedCallSequenceInputs() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["call", "list_apps", "--calls", "[]"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(
                    message: "call sequence does not accept a tool name, --args, or --args-file",
                    helpCommand: "call"
                )
            )
        }
    }

    func testCLIRejectsSleepForSingleToolCall() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["call", "list_apps", "--sleep", "0.5"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(
                    message: "--sleep is only supported with --calls or --calls-file",
                    helpCommand: "call"
                )
            )
        }
    }

    func testCLIRejectsInvalidSequenceSleepValue() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["call", "--calls", "[]", "--sleep", "-1"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(
                    message: "--sleep requires a non-negative number of seconds",
                    helpCommand: "call"
                )
            )
        }
    }

    func testCLIRejectsUnknownOption() {
        XCTAssertThrowsError(try parseOpenComputerUseCLI(arguments: ["--verbose"])) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(
                    message: "Unknown option: --verbose",
                    helpCommand: nil
                )
            )
        }
    }

    func testGeneralHelpListsCommandsAndGlobalFlags() {
        let help = openComputerUseHelpText()

        XCTAssertTrue(help.contains("open-computer-use [command] [options]"))
        XCTAssertTrue(help.contains("snapshot <app>"))
        XCTAssertTrue(help.contains("call <tool>"))
        XCTAssertTrue(help.contains("-h, --help"))
        XCTAssertTrue(help.contains("-v, --version"))
    }

    func testResolvedVersionFallsBackWhenBundleHasNoVersionMetadata() {
        XCTAssertEqual(resolvedOpenComputerUseVersion(bundle: Bundle(for: Self.self)), openComputerUseVersion)
    }

    func testBoundedScreenshotPNGDataShrinksLargeScreenshots() throws {
        let image = try makeNoisyTestImage(width: 800, height: 600)
        let data = try XCTUnwrap(boundedScreenshotPNGData(
            for: image,
            maxDimension: 320
        ))
        let size = try imageSize(in: data)

        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 240)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 320)
    }

    func testBoundedScreenshotPNGDataKeepsSmallScreenshotsAtOriginalSize() throws {
        let image = try makeSolidTestImage(width: 32, height: 24)
        let data = try XCTUnwrap(boundedScreenshotPNGData(for: image, maxDimension: 320))
        let size = try imageSize(in: data)

        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 24)
    }

    func testToolDefinitionCount() {
        XCTAssertEqual(ToolDefinitions.all.count, 12)
        XCTAssertEqual(
            ToolDefinitions.all.map(\.name).sorted(),
            [
                "click",
                "drag",
                "get_app_state",
                "list_apps",
                "perform_secondary_action",
                "press_key",
                "query",
                "scroll",
                "select_text",
                "set_position",
                "set_value",
                "type_text",
            ]
        )
    }

    func testReadToolArgumentsAcceptsJSONObject() throws {
        let arguments = try readOpenComputerUseToolArguments(
            json: #"{"app":"TextEdit","pages":2}"#,
            file: nil
        )

        XCTAssertEqual(arguments["app"] as? String, "TextEdit")
        XCTAssertEqual((arguments["pages"] as? NSNumber)?.intValue, 2)
    }

    func testElementIndexAcceptsNumericToolArgument() throws {
        let arguments = try readOpenComputerUseToolArguments(
            json: #"{"app":"TextEdit","element_index":0}"#,
            file: nil
        )

        XCTAssertEqual(normalizedElementIndexArgument(arguments["element_index"]), "0")
    }

    func testElementIndexAcceptsNumericCallSequenceArgument() throws {
        let calls = try readOpenComputerUseCallSequence(
            json: #"[{"tool":"click","args":{"app":"TextEdit","element_index":0}}]"#,
            file: nil
        )

        XCTAssertEqual(normalizedElementIndexArgument(calls[0].arguments["element_index"]), "0")
    }

    func testElementIndexRejectsMissingEmptyAndFractionalArguments() {
        XCTAssertNil(normalizedElementIndexArgument(nil))
        XCTAssertNil(normalizedElementIndexArgument(""))
        XCTAssertNil(normalizedElementIndexArgument(1.5))
    }

    func testReadToolArgumentsRejectsNonObject() {
        XCTAssertThrowsError(try readOpenComputerUseToolArguments(json: #"["TextEdit"]"#, file: nil)) { error in
            XCTAssertEqual(
                error as? OpenComputerUseCLIError,
                OpenComputerUseCLIError(message: "--args must be a JSON object", helpCommand: "call")
            )
        }
    }

    func testReadCallSequenceAcceptsJSONArrays() throws {
        let calls = try readOpenComputerUseCallSequence(
            json: #"[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"name":"press_key","arguments":{"app":"TextEdit","key":"Return"}}]"#,
            file: nil
        )

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].tool, "get_app_state")
        XCTAssertEqual(calls[0].arguments["app"] as? String, "TextEdit")
        XCTAssertEqual(calls[1].tool, "press_key")
        XCTAssertEqual(calls[1].arguments["key"] as? String, "Return")
    }

    func testRunCallSequenceStopsAfterFirstToolError() throws {
        let output = try runOpenComputerUseCall(
            .sequence(
                callsJSON: #"[{"tool":"not_a_tool"},{"tool":"list_apps"}]"#,
                callsFile: nil,
                interCallDelay: openComputerUseDefaultInterCallDelay
            )
        )

        let outputs = try XCTUnwrap(output.jsonObject as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertTrue(output.hasToolError)
    }

    func testRunCallSequenceSleepsBetweenSuccessfulOperations() throws {
        var recordedSleeps: [TimeInterval] = []

        let output = try runOpenComputerUseCall(
            .sequence(
                callsJSON: #"[{"tool":"list_apps"},{"tool":"list_apps"},{"tool":"list_apps"}]"#,
                callsFile: nil,
                interCallDelay: openComputerUseDefaultInterCallDelay
            ),
            sleepHandler: { recordedSleeps.append($0) }
        )

        let outputs = try XCTUnwrap(output.jsonObject as? [[String: Any]])
        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(recordedSleeps, [openComputerUseDefaultInterCallDelay, openComputerUseDefaultInterCallDelay])
        XCTAssertFalse(output.hasToolError)
    }

    func testMacOSAppAgentProxyDecisionRoutesAutomationCommandsThroughAppBundle() {
        for command in [
            OpenComputerUseCLICommand.mcp,
            .doctor(),
            .listApps,
            .snapshot(app: "TextEdit"),
            .call(.single(toolName: "list_apps", argumentsJSON: nil, argumentsFile: nil)),
        ] {
            XCTAssertTrue(shouldUseMacOSAppAgentProxy(
                command: command,
                proxyDisabled: false,
                appBundleAvailable: true,
                runningFromLaunchServicesAppInstance: false
            ))
        }
    }

    func testAppNameResolutionPrefersRegularAppsAndDisplayNames() {
        let ranked = [
            AppDiscovery.ResolutionCandidate(name: "Safari", executableName: nil, isRegularApp: true),
            AppDiscovery.ResolutionCandidate(name: "Browser", executableName: "Safari", isRegularApp: true),
            AppDiscovery.ResolutionCandidate(name: "Safari", executableName: nil, isRegularApp: false),
            AppDiscovery.ResolutionCandidate(name: "Browser Helper", executableName: "Safari", isRegularApp: false),
        ]
        for preferred in ranked.indices {
            for fallback in ranked.indices where fallback > preferred {
                XCTAssertEqual(AppDiscovery.bestResolutionIndex(of: [ranked[fallback], ranked[preferred]], matching: "sAfArI"), 1)
                XCTAssertEqual(AppDiscovery.bestResolutionIndex(of: [ranked[preferred], ranked[fallback]], matching: "sAfArI"), 0)
            }
        }
        for candidate in ranked {
            XCTAssertEqual(AppDiscovery.bestResolutionIndex(of: [candidate, candidate], matching: "Safari"), 0)
        }
        XCTAssertNil(AppDiscovery.bestResolutionIndex(of: ranked, matching: "missing"))
        XCTAssertNil(AppDiscovery.bestResolutionIndex(of: [], matching: "Safari"))
    }

    func testMacOSAppAgentProxyDecisionKeepsNonAutomationCommandsLocal() {
        for command in [
            OpenComputerUseCLICommand.turnEnded(payload: nil),
            .help(command: nil),
            .version,
        ] {
            XCTAssertFalse(shouldUseMacOSAppAgentProxy(
                command: command,
                proxyDisabled: false,
                appBundleAvailable: true,
                runningFromLaunchServicesAppInstance: false
            ))
        }
    }

    func testMacOSAppAgentProxyDecisionDoesNotProxyLaunchServicesAppOpen() {
        XCTAssertTrue(shouldUseMacOSAppAgentProxy(
            command: .launchOnboarding,
            proxyDisabled: false,
            appBundleAvailable: true,
            runningFromLaunchServicesAppInstance: false
        ))
        XCTAssertFalse(shouldUseMacOSAppAgentProxy(
            command: .launchOnboarding,
            proxyDisabled: false,
            appBundleAvailable: true,
            runningFromLaunchServicesAppInstance: true
        ))
    }

    func testMacOSAppAgentProxyDecisionHonorsDisableAndMissingBundle() {
        XCTAssertFalse(shouldUseMacOSAppAgentProxy(
            command: .doctor(),
            proxyDisabled: true,
            appBundleAvailable: true,
            runningFromLaunchServicesAppInstance: false
        ))
        XCTAssertFalse(shouldUseMacOSAppAgentProxy(
            command: .doctor(),
            proxyDisabled: false,
            appBundleAvailable: false,
            runningFromLaunchServicesAppInstance: false
        ))
    }

    func testPermissionDiagnosticsListsMissingPermissionsInCanonicalOrder() {
        let diagnostics = PermissionDiagnostics(
            accessibilityTrusted: false,
            screenCaptureGranted: true
        )

        XCTAssertEqual(diagnostics.missingPermissions, [.accessibility])
    }

    func testPermissionDiagnosticsHasNoMissingPermissionsWhenAllGranted() {
        let diagnostics = PermissionDiagnostics(
            accessibilityTrusted: true,
            screenCaptureGranted: true
        )

        XCTAssertTrue(diagnostics.missingPermissions.isEmpty)
    }

    func testListedAppDescriptorRendersFrontmostBeforeRunning() {
        let descriptor = ListedAppDescriptor(
            name: "Sample",
            bundleIdentifier: "com.example.Sample",
            isRunning: true,
            isFrontmost: true,
            lastUsed: nil,
            uses: nil
        )

        XCTAssertEqual(descriptor.renderedLine, "Sample — com.example.Sample [frontmost, running]")
    }

    func testListedAppSortingPrefersFrontmostRunningApp() {
        let frontmost = ListedAppDescriptor(
            name: "Front",
            bundleIdentifier: "com.example.Front",
            isRunning: true,
            isFrontmost: true,
            lastUsed: nil,
            uses: nil
        )
        let frequent = ListedAppDescriptor(
            name: "Frequent",
            bundleIdentifier: "com.example.Frequent",
            isRunning: true,
            isFrontmost: false,
            lastUsed: Date(),
            uses: 999
        )

        XCTAssertTrue(AppDiscovery.compareListedApps(frontmost, frequent))
        XCTAssertFalse(AppDiscovery.compareListedApps(frequent, frontmost))
    }

    func testPreferredPermissionAppBundleURLPrefersInstalledCopyOverTransientRunningCopy() {
        let installed = URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/open-computer-use/dist/Open Computer Use.app")
        let running = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use/dist/Open Computer Use.app")
        let fallback = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use-debug/dist/Open Computer Use.app")

        let resolved = PermissionSupport.preferredPermissionAppBundleURL(
            preferredInstalledBundleURL: installed,
            runningBundleURL: running,
            fallbackDevelopmentBundleURL: fallback
        )

        XCTAssertEqual(resolved, installed)
    }

    func testPreferredPermissionAppBundleURLPrefersRunningDevelopmentCopy() {
        let installed = URL(fileURLWithPath: "/Applications/Open Computer Use.app")
        let running = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use/dist/Open Computer Use (Dev).app")
        let fallback = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use-debug/dist/Open Computer Use (Dev).app")

        let resolved = PermissionSupport.preferredPermissionAppBundleURL(
            preferredInstalledBundleURL: installed,
            runningBundleURL: running,
            fallbackDevelopmentBundleURL: fallback,
            preferRunningBundle: true
        )

        XCTAssertEqual(resolved, running)
    }

    func testPreferredPermissionAppBundleURLCanPreferRunningReleaseCopyOverStaleInstalledCopy() {
        let staleInstalled = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use/dist/npm/open-computer-use/dist/Open Computer Use.app")
        let running = URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/open-computer-use/dist/Open Computer Use.app")

        let resolved = PermissionSupport.preferredPermissionAppBundleURL(
            preferredInstalledBundleURL: staleInstalled,
            runningBundleURL: running,
            fallbackDevelopmentBundleURL: nil,
            preferRunningBundle: true
        )

        XCTAssertEqual(resolved, running)
    }

    func testPreferredInstalledAppBundleURLUsesFirstDiscoveredInstalledCopy() {
        let applications = URL(fileURLWithPath: "/Applications/Open Computer Use.app")
        let npm = URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/open-computer-use/dist/Open Computer Use.app")
        let duplicateApplications = URL(fileURLWithPath: "/Applications/Open Computer Use.app")

        let resolved = PermissionSupport.preferredInstalledAppBundleURL(
            candidates: [applications, npm, duplicateApplications]
        )

        XCTAssertEqual(resolved, applications)
    }

    func testPermissionClientsKeepStableBundleIdentityAheadOfTransientAppPath() {
        let installed = URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/open-computer-use/dist/Open Computer Use.app")
        let running = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use/dist/Open Computer Use.app")

        let clients = PermissionSupport.permissionClients(
            primaryBundleURL: installed,
            runningBundleURL: running,
            mainBundleIdentifier: PermissionSupport.bundleIdentifier
        )

        XCTAssertEqual(
            clients,
            [
                PermissionClientRecord(identifier: PermissionSupport.bundleIdentifier, type: 0),
                PermissionClientRecord(identifier: installed.path, type: 1),
                PermissionClientRecord(identifier: running.path, type: 1),
            ]
        )
    }

    func testPermissionClientsKeepDevelopmentBundleIdentitySeparateFromRelease() {
        let running = URL(fileURLWithPath: "/Users/example/projects/open-codex-computer-use/dist/Open Computer Use (Dev).app")

        let clients = PermissionSupport.permissionClients(
            primaryBundleURL: running,
            runningBundleURL: running,
            mainBundleIdentifier: PermissionSupport.developmentBundleIdentifier,
            includeCanonicalBundleIdentifier: false
        )

        XCTAssertEqual(
            clients,
            [
                PermissionClientRecord(identifier: PermissionSupport.developmentBundleIdentifier, type: 0),
                PermissionClientRecord(identifier: running.path, type: 1),
            ]
        )
    }

    func testTCCAuthorizationGrantedTreatsAnyGrantedCandidateAsGranted() {
        XCTAssertTrue(tccAuthorizationGranted(authValues: [0, 2]))
        XCTAssertFalse(tccAuthorizationGranted(authValues: [0, nil]))
        XCTAssertFalse(tccAuthorizationGranted(authValues: []))
    }

    func testPermissionGrantedKeepsRuntimePreflightAuthoritativeForCurrentProcess() {
        XCTAssertTrue(permissionGranted(persisted: false, runtime: true))
        XCTAssertTrue(permissionGranted(persisted: nil, runtime: true))
        XCTAssertTrue(permissionGranted(persisted: true, runtime: false))
        XCTAssertFalse(permissionGranted(persisted: false, runtime: false))
        XCTAssertFalse(permissionGranted(persisted: nil, runtime: false))
    }

    func testKeyPressParserSupportsCommandStyleChord() throws {
        let parsed = try KeyPressParser.parse("super+c")
        XCTAssertEqual(parsed.displayValue, "c")
        XCTAssertEqual(parsed.modifiers.count, 1)
    }

    func testKeyPressParserSupportsOfficialXdotoolAliases() throws {
        XCTAssertEqual(try KeyPressParser.parse("BackSpace").displayValue, "backspace")
        XCTAssertEqual(try KeyPressParser.parse("Page_Up").displayValue, "page_up")
        XCTAssertEqual(try KeyPressParser.parse("Prior").displayValue, "prior")
        XCTAssertEqual(try KeyPressParser.parse("KP_9").displayValue, "kp_9")
        XCTAssertEqual(try KeyPressParser.parse("KP_Enter").displayValue, "kp_enter")
        XCTAssertEqual(try KeyPressParser.parse("F12").displayValue, "f12")
    }

    func testInitializeResponseContainsToolsCapability() throws {
        let server = StdioMCPServer(service: ComputerUseService())
        let response = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"test","version":"1.1.2"},"capabilities":{}}}"#)
        XCTAssertNotNil(response)
        XCTAssertTrue(response!.contains(#""name":"open-computer-use""#))
        XCTAssertTrue(response!.contains(#""tools":{"listChanged":false}"#))
    }

    func testInitializeResponseContainsComputerUseInstructions() throws {
        let server = StdioMCPServer(service: ComputerUseService())
        let response = try XCTUnwrap(
            server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"test","version":"1.1.2"},"capabilities":{}}}"#)
        )
        let data = try XCTUnwrap(response.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let instructions = try XCTUnwrap(result["instructions"] as? String)

        XCTAssertEqual(instructions, computerUseServerInstructions)
    }

    func testMCPTurnEndedNotificationResetsBackgroundStateWithoutResponse() {
        var resetCount = 0
        let server = StdioMCPServer(
            service: ComputerUseService(),
            backgroundStateReset: { resetCount += 1 }
        )
        let response = server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/turn-ended","params":{"type":"agent-turn-complete"}}"#)

        XCTAssertNil(response)
        XCTAssertEqual(resetCount, 1)
    }

    func testWindowRelativeFrameUsesSharedGlobalCoordinates() {
        let window = CGRect(x: 1486, y: 556, width: 919, height: 644)
        let child = CGRect(x: 1486, y: 556, width: 919, height: 644)
        let textField = CGRect(x: 180, y: 176, width: 36, height: 18)
        let textFieldGlobal = CGRect(x: window.minX + textField.minX, y: window.minY + textField.minY, width: textField.width, height: textField.height)

        XCTAssertEqual(windowRelativeFrame(elementFrame: child, windowBounds: window), CGRect(x: 0, y: 0, width: 919, height: 644))
        XCTAssertEqual(windowRelativeFrame(elementFrame: textFieldGlobal, windowBounds: window), textField)
    }

    func testToolDescriptionsMatchOfficialComputerUseSurface() {
        let tools = Dictionary(uniqueKeysWithValues: ToolDefinitions.all.map { ($0.name, $0) })

        XCTAssertEqual(
            tools["get_app_state"]?.description,
            "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`."
        )
        XCTAssertTrue(tools["press_key"]?.description.contains("xdotool") == true)
        XCTAssertEqual(
            tools["click"]?.annotations["destructiveHint"] as? Bool,
            false
        )
        XCTAssertEqual(
            tools["get_app_state"]?.annotations["readOnlyHint"] as? Bool,
            nil
        )
        XCTAssertEqual(
            tools["click"]?.inputSchema["additionalProperties"] as? Bool,
            false
        )
        XCTAssertEqual(
            ((tools["click"]?.inputSchema["properties"] as? [String: [String: Any]])?["mouse_button"]?["enum"] as? [String]) ?? [],
            ["left", "right", "middle"]
        )
        XCTAssertEqual(
            ((tools["click"]?.inputSchema["properties"] as? [String: [String: Any]])?["click_method"]?["enum"] as? [String]) ?? [],
            ["auto", "accessibility", "app_post", "sky_click", "global"]
        )
        let dragDescription = tools["drag"]?.description ?? ""
        XCTAssertTrue(dragDescription.contains("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1"))
        XCTAssertTrue(dragDescription.contains("window moves, text selection, or Finder drag-and-drop"))
        XCTAssertTrue(dragDescription.hasSuffix("This tool is part of plugin `Computer Use`."))
        let getAppStateSchema = tools["get_app_state"]?.inputSchema
        let getAppStateProperties = getAppStateSchema?["properties"] as? [String: [String: Any]]
        XCTAssertNil(getAppStateProperties?["show_full_text"])
        let textLimitAnyOf = getAppStateProperties?["text_limit"]?["anyOf"] as? [[String: Any]]
        XCTAssertEqual(textLimitAnyOf?[0]["type"] as? String, "integer")
        XCTAssertEqual(textLimitAnyOf?[0]["minimum"] as? Int, 1)
        XCTAssertEqual(textLimitAnyOf?[1]["type"] as? String, "string")
        XCTAssertEqual(textLimitAnyOf?[1]["enum"] as? [String], ["max"])
        XCTAssertEqual(getAppStateProperties?["max_tree_nodes"]?["type"] as? String, "integer")
        XCTAssertEqual(getAppStateProperties?["max_tree_nodes"]?["minimum"] as? Int, 1)
        XCTAssertEqual(getAppStateProperties?["max_tree_depth"]?["type"] as? String, "integer")
        XCTAssertEqual(getAppStateProperties?["max_tree_depth"]?["minimum"] as? Int, 1)
        XCTAssertEqual(getAppStateSchema?["required"] as? [String], ["app"])
        let scrollPages = (tools["scroll"]?.inputSchema["properties"] as? [String: [String: Any]])?["pages"]
        XCTAssertEqual(scrollPages?["type"] as? String, "number")
        XCTAssertEqual(
            scrollPages?["description"] as? String,
            "Number of pages to scroll. Fractional values are supported. Defaults to 1"
        )
        XCTAssertEqual(
            tools["select_text"]?.description,
            "Select text inside a text element, or place the text cursor before or after it. Provide text exactly as it appears in the accessibility tree, including any Markdown formatting. If the text is not unique, provide surrounding prefix or suffix text to disambiguate it. This tool is part of plugin `Computer Use`."
        )
        let selectTextSchema = tools["select_text"]?.inputSchema
        let selectTextProperties = selectTextSchema?["properties"] as? [String: [String: Any]]
        XCTAssertEqual(selectTextSchema?["required"] as? [String], ["app", "element_index", "text"])
        XCTAssertEqual(selectTextSchema?["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            selectTextProperties?["selection"]?["enum"] as? [String],
            ["text", "cursor_before", "cursor_after"]
        )
        XCTAssertEqual(
            selectTextProperties?["selection"]?["description"] as? String,
            "Whether to select the text or place the cursor before or after it. Defaults to text."
        )
        XCTAssertEqual(selectTextProperties?["element_index"]?["description"] as? String, "Text element identifier")
        XCTAssertEqual(
            selectTextProperties?["prefix"]?["description"] as? String,
            "Optional text immediately before the target, used to disambiguate repeated matches"
        )
        XCTAssertEqual(
            selectTextProperties?["suffix"]?["description"] as? String,
            "Optional text immediately after the target, used to disambiguate repeated matches"
        )
        XCTAssertEqual(
            selectTextProperties?["text"]?["description"] as? String,
            "Target text as shown in the accessibility tree"
        )
        let setPositionSchema = tools["set_position"]?.inputSchema
        let setPositionProperties = setPositionSchema?["properties"] as? [String: [String: Any]]
        XCTAssertEqual(setPositionSchema?["required"] as? [String], ["app", "element_index", "x", "y"])
        XCTAssertEqual(setPositionSchema?["additionalProperties"] as? Bool, false)
        XCTAssertEqual(setPositionProperties.map { Set($0.keys) }, ["app", "element_index", "x", "y", "width", "height"])
        XCTAssertEqual(setPositionProperties?["width"]?["type"] as? String, "number")
        XCTAssertTrue(setPositionProperties?["x"]?["description"].map { "\($0)".contains("screenshot pixel coordinates") } ?? false)
        XCTAssertTrue(tools["set_position"]?.description.hasSuffix("This tool is part of plugin `Computer Use`.") ?? false)
    }

    func testSelectTextRejectsInvalidSelectionMode() {
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(
            name: "select_text",
            arguments: ["app": "Sublime Text", "element_index": "14", "text": "abc", "selection": "sideways"]
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.primaryText, "selection must be one of text, cursor_before, cursor_after")
    }

    func testDispatcherMissingArgumentsMatchOfficialToolText() {
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(name: "type_text", arguments: ["app": "Sublime Text"])
        let emptyResult = dispatcher.callToolAsResult(name: "type_text", arguments: ["app": "Sublime Text", "text": ""])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.primaryText, "Missing required argument: text")
        XCTAssertTrue(emptyResult.isError)
        XCTAssertEqual(emptyResult.primaryText, "Missing required argument: text")
    }

    func testTypeTextUnicodeChunksPreserveGraphemeClusters() {
        let text = "（ocu发的）👩🏽‍💻e\u{301}𠀀"
        let chunks = InputSimulation.keyboardUnicodeChunks(for: text, maxUTF16Units: 8)
        let decoded = chunks
            .map { String(decoding: $0, as: UTF16.self) }
            .joined()

        XCTAssertEqual(decoded, text)
        XCTAssertTrue(chunks.count > 1)
        XCTAssertTrue(chunks.allSatisfy { chunk in
            let decodedChunk = String(decoding: chunk, as: UTF16.self)
            return decodedChunk.unicodeScalars.allSatisfy { $0.value != 0xFFFD }
        })
        for cluster in ["👩🏽‍💻", "e\u{301}", "𠀀"] {
            XCTAssertEqual(
                chunks.filter { String(decoding: $0, as: UTF16.self).contains(cluster) }.count,
                1
            )
        }
    }

    func testScrollRejectsInvalidDirectionWithOfficialMessage() {
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(
            name: "scroll",
            arguments: ["app": "Sublime Text", "element_index": "14", "direction": "sideways", "pages": 1]
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.primaryText, "Invalid scroll direction: sideways")
    }

    func testScrollRejectsNonPositivePagesWithOfficialMessage() {
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(
            name: "scroll",
            arguments: ["app": "Sublime Text", "element_index": "14", "direction": "down", "pages": 0.0]
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.primaryText, "pages must be > 0")
    }

    func testSecondaryActionInvalidMessageMatchesOfficialShape() {
        XCTAssertEqual(
            invalidSecondaryActionErrorMessage(action: "NoSuchAction", elementIndex: 14),
            "NoSuchAction is not a valid secondary action for 14"
        )
    }

    func testSyntheticTextClickUsesLeadingSafePointOnly() {
        let frame = CGRect(x: 40, y: 20, width: 300, height: 48)
        let points = localClickActionPoints(frame: frame, isSyntheticText: true)

        XCTAssertEqual(points, [CGPoint(x: 130, y: 44)])
        XCTAssertFalse(points.contains(CGPoint(x: 190, y: 44)))
    }

    func testNormalClickKeepsCenterThenLeadingFallback() {
        let frame = CGRect(x: 40, y: 20, width: 300, height: 48)

        XCTAssertEqual(
            localClickActionPoints(frame: frame, isSyntheticText: false),
            [CGPoint(x: 190, y: 44), CGPoint(x: 130, y: 44)]
        )
    }

    func testSyntheticSideActionFilterRejectsTrailingDoneButton() {
        XCTAssertTrue(
            isLikelySyntheticSideActionCandidate(
                parentFrame: CGRect(x: 40, y: 20, width: 300, height: 48),
                candidateFrame: CGRect(x: 296, y: 24, width: 36, height: 36),
                hasPrimaryAction: true,
                labels: ["完成"]
            )
        )
    }

    func testSyntheticSideActionFilterKeepsMainRowPreviewContainingDone() {
        XCTAssertFalse(
            isLikelySyntheticSideActionCandidate(
                parentFrame: CGRect(x: 40, y: 20, width: 300, height: 48),
                candidateFrame: CGRect(x: 48, y: 22, width: 236, height: 44),
                hasPrimaryAction: true,
                labels: ["AK账号管控 @所有人 变更完成，如果有问题，请联系我"]
            )
        )
    }

    func testSyntheticSideActionFilterKeepsLargeRowNamedDone() {
        XCTAssertFalse(
            isLikelySyntheticSideActionCandidate(
                parentFrame: CGRect(x: 40, y: 20, width: 300, height: 48),
                candidateFrame: CGRect(x: 40, y: 20, width: 300, height: 48),
                hasPrimaryAction: true,
                labels: ["完成"]
            )
        )
    }

    func testHitRecordDescendantScanRejectsBroadWebAreaHit() {
        XCTAssertFalse(
            shouldScanDescendantsOfHitRecord(
                originalFrame: CGRect(x: 40, y: 120, width: 300, height: 48),
                hitFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
        )
    }

    func testHitRecordDescendantScanKeepsNearbyRowHit() {
        XCTAssertTrue(
            shouldScanDescendantsOfHitRecord(
                originalFrame: CGRect(x: 40, y: 120, width: 300, height: 48),
                hitFrame: CGRect(x: 32, y: 112, width: 320, height: 56)
            )
        )
    }

    func testContainingRowActionAcceptsTightClickableAncestor() {
        XCTAssertTrue(
            isLikelyContainingRowActionFrame(
                targetFrame: CGRect(x: 132, y: 381, width: 268, height: 44),
                candidateFrame: CGRect(x: 124, y: 373, width: 284, height: 60),
                hasPrimaryAction: true
            )
        )
    }

    func testContainingRowActionRejectsBroadWebArea() {
        XCTAssertFalse(
            isLikelyContainingRowActionFrame(
                targetFrame: CGRect(x: 132, y: 381, width: 268, height: 44),
                candidateFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                hasPrimaryAction: true
            )
        )
    }

    func testContainingRowActionRequiresPrimaryAction() {
        XCTAssertFalse(
            isLikelyContainingRowActionFrame(
                targetFrame: CGRect(x: 132, y: 381, width: 268, height: 44),
                candidateFrame: CGRect(x: 124, y: 373, width: 284, height: 60),
                hasPrimaryAction: false
            )
        )
    }

    func testContainingWebRowOptimizationRejectsChromeWebGroups() {
        XCTAssertFalse(
            shouldPreferContainingWebRowAXClickCandidate(
                role: kAXGroupRole as String,
                isSyntheticText: false,
                hasWebAreaAncestor: true,
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
    }

    func testContainingWebRowOptimizationRejectsChromeSyntheticText() {
        XCTAssertFalse(
            shouldPreferContainingWebRowAXClickCandidate(
                role: kAXStaticTextRole as String,
                isSyntheticText: true,
                hasWebAreaAncestor: true,
                appName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
    }

    func testContainingWebRowOptimizationKeepsLarkSyntheticRows() {
        XCTAssertTrue(
            shouldPreferContainingWebRowAXClickCandidate(
                role: kAXStaticTextRole as String,
                isSyntheticText: true,
                hasWebAreaAncestor: true,
                appName: "Lark",
                bundleIdentifier: "com.electron.lark"
            )
        )
    }

    func testContainingWebRowOptimizationRequiresWebAreaAncestor() {
        XCTAssertFalse(
            shouldPreferContainingWebRowAXClickCandidate(
                role: kAXGroupRole as String,
                isSyntheticText: false,
                hasWebAreaAncestor: false,
                appName: "Lark",
                bundleIdentifier: "com.electron.lark"
            )
        )
    }

    func testActivationOnlyClickFallbackRejectsPlainStaticText() {
        XCTAssertFalse(canUseActivationOnlyClickFallback(role: kAXStaticTextRole as String))
    }

    func testActivationOnlyClickFallbackKeepsWindowRaisePath() {
        XCTAssertTrue(canUseActivationOnlyClickFallback(role: kAXWindowRole as String))
    }

    func testKeyboardTextFallbackRejectsPlainWebArea() {
        XCTAssertFalse(
            canUseKeyboardTextFallback(
                role: "AXWebArea",
                roleDescription: "HTML content",
                isValueSettable: false
            )
        )
    }

    func testKeyboardTextFallbackAcceptsEditableTextRole() {
        XCTAssertTrue(
            canUseKeyboardTextFallback(
                role: kAXTextFieldRole as String,
                roleDescription: "text field",
                isValueSettable: false
            )
        )
    }

    func testKeyboardTextFallbackAcceptsSettableValueElement() {
        XCTAssertTrue(
            canUseKeyboardTextFallback(
                role: kAXGroupRole as String,
                roleDescription: "text entry area",
                isValueSettable: true
            )
        )
    }

    func testSnapshotRenderedTextStartsDirectlyWithAppHeader() {
        let snapshot = makeSnapshot(
            treeLines: ["\t0 standard window Sample Chat"],
            focusedSummary: "247 text entry area"
        )

        let rendered = snapshot.renderedText(style: .actionResult)
        let lines = rendered.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "App=com.example.SampleChat (pid 18465)")
        XCTAssertEqual(lines.dropFirst().first, "Window: \"Sample Chat\", App: Sample Chat.")
        XCTAssertFalse(rendered.contains("Computer Use state (CUA App Version: 750)"))
        XCTAssertFalse(rendered.contains("<app_state>"))
        XCTAssertFalse(rendered.contains("</app_state>"))
    }

    func testSnapshotSelectedTextUsesOfficialSingleLineFormat() {
        let snapshot = makeSnapshot(
            treeLines: ["\t38 search text field (settable, string) Codex"],
            focusedSummary: nil,
            selectedText: "Codex"
        )

        let rendered = snapshot.renderedText(style: .actionResult)

        XCTAssertTrue(rendered.contains("Selected text: [Codex]"))
        XCTAssertFalse(rendered.contains("Selected text: ```"))
        XCTAssertFalse(rendered.contains("Pay special attention to the content selected by the user"))
    }

    func testAccessibilityTreeBudgetAllowsDeepElectronWebViews() {
        XCTAssertEqual(accessibilityTreeMaxNodeCount, 1200)
        XCTAssertEqual(accessibilityTreeMaxDepth, 64)
        XCTAssertTrue(shouldContinueRendering(nextIndex: 120, depth: 16))
        XCTAssertTrue(shouldContinueRendering(nextIndex: 1199, depth: 63))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 1200, depth: 20))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 120, depth: 64))
        let customLimits = AccessibilityTreeLimits(maxNodeCount: 3000, maxDepth: 96)
        XCTAssertTrue(shouldContinueRendering(nextIndex: 1200, depth: 64, limits: customLimits))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 3000, depth: 20, limits: customLimits))
        XCTAssertFalse(shouldContinueRendering(nextIndex: 20, depth: 96, limits: customLimits))
    }

    func testAccessibilityRendererElidesEmptyGenericElectronWrappers() {
        XCTAssertTrue(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 3
        ))
        XCTAssertTrue(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 0
        ))
        XCTAssertFalse(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 0,
            preservesCompactGenericActionTarget: true
        ))
        XCTAssertFalse(shouldElideNode(
            role: kAXGroupRole as String,
            title: "Send",
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 3
        ))
        XCTAssertFalse(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 3,
            genericTextSummary: "AgentSphere 17:18 okay"
        ))
        XCTAssertFalse(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 3,
            webAreaDepth: 4
        ))
        XCTAssertTrue(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 1,
            webAreaDepth: 4
        ))
        XCTAssertTrue(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 0,
            webAreaDepth: 4
        ))
        XCTAssertFalse(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 2,
            webAreaDepth: 8
        ))
        XCTAssertTrue(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: [],
            actions: [],
            childCount: 1,
            webAreaDepth: 8
        ))
        XCTAssertTrue(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: ["settable", "string"],
            actions: [],
            childCount: 1
        ))
        XCTAssertFalse(shouldElideNode(
            role: kAXGroupRole as String,
            title: nil,
            label: nil,
            value: nil,
            identifier: nil,
            traits: ["settable", "string"],
            actions: [],
            childCount: 0
        ))
    }

    func testAccessibilityRendererRecognizesPrimaryClickActions() {
        XCTAssertTrue(hasPrimaryClickAction([kAXPressAction as String]))
        XCTAssertTrue(hasPrimaryClickAction([kAXConfirmAction as String]))
        XCTAssertTrue(hasPrimaryClickAction(["AXOpen"]))
        XCTAssertTrue(hasPrimaryClickAction(["axpress"]))
        XCTAssertFalse(hasPrimaryClickAction(["AXShowMenu", "AXScrollToVisible", "AXRaise"]))
    }

    func testAccessibilityRendererTreatsGenericPrimaryActionsAsSummaryBoundaries() {
        XCTAssertTrue(isGenericPrimaryActionSummaryBoundary(
            role: kAXGroupRole as String,
            actions: [kAXPressAction as String]
        ))
        XCTAssertTrue(isGenericPrimaryActionSummaryBoundary(
            role: kAXUnknownRole as String,
            actions: ["AXOpen"]
        ))
        XCTAssertFalse(isGenericPrimaryActionSummaryBoundary(
            role: kAXGroupRole as String,
            actions: ["AXShowMenu", "AXScrollToVisible"]
        ))
        XCTAssertFalse(isGenericPrimaryActionSummaryBoundary(
            role: kAXButtonRole as String,
            actions: [kAXPressAction as String]
        ))
        XCTAssertFalse(isGenericPrimaryActionSummaryBoundary(
            role: "AXLink",
            actions: [kAXPressAction as String]
        ))
    }

    func testAccessibilityRendererUsesSafariCustomActionDescriptionName() {
        XCTAssertEqual(
            meaningfulActions(
                ["Name:close tab Target:SafariTab Selector:_close Button Clicked:"],
                role: kAXButtonRole as String
            ),
            ["close tab"]
        )
        XCTAssertNil(accessibilityActionDescriptionName("Namespace:close tab Target:SafariTab"))
    }

    func testSecondaryActionMatchingKeepsFilteredRawActionsAligned() {
        let service = ComputerUseService()
        let closeTab = "Name:close tab Target:SafariTab Selector:_close Button Clicked:"
        let record = ElementRecord(
            index: 48,
            identifier: nil,
            element: nil,
            localFrame: nil,
            role: kAXButtonRole as String,
            rawActions: [kAXPressAction as String, closeTab],
            prettyActions: ["close tab"]
        )

        XCTAssertEqual(service.matchingAction(requested: "close-tab", record: record), closeTab)
        XCTAssertEqual(service.matchingAction(requested: kAXPressAction as String, record: record), kAXPressAction as String)
        XCTAssertNil(service.matchingAction(requested: "Press", record: record))
    }

    func testSecondaryActionSelectorsDoNotShadowRawActionNames() {
        let service = ComputerUseService()
        // Include both a filtered action and a visible action, and exercise the
        // case-insensitive exact lookup used by the executor.
        for nativeAction in ["AXPress", "AXRaise"] {
            for customName in [nativeAction, nativeAction.lowercased()] {
                let customAction = "Name:\(customName) Target:CustomTarget Selector:_custom:"
                for rawActions in [[nativeAction, customAction], [customAction, nativeAction]] {
                    let emitted = meaningfulActions(rawActions, role: kAXButtonRole as String)
                    let visible = meaningfulRawActions(rawActions, role: kAXButtonRole as String)
                    let record = ElementRecord(
                        index: 50,
                        identifier: nil,
                        element: nil,
                        localFrame: nil,
                        role: kAXButtonRole as String,
                        rawActions: rawActions,
                        prettyActions: emitted
                    )

                    XCTAssertTrue(emitted.contains(customAction))
                    XCTAssertEqual(emitted.count, visible.count)
                    for (selector, expected) in zip(emitted, visible) {
                        XCTAssertEqual(service.matchingAction(requested: selector, record: record), expected)
                    }
                    XCTAssertEqual(service.matchingAction(requested: nativeAction, record: record), nativeAction)
                }
            }
        }
    }

    func testSecondaryActionMatchingRejectsAmbiguousDisplayNames() {
        let service = ComputerUseService()
        let record = ElementRecord(
            index: 49,
            identifier: nil,
            element: nil,
            localFrame: nil,
            role: kAXButtonRole as String,
            rawActions: [
                "Name:close tab Target:FirstTab Selector:_close:",
                "Name:close tab Target:SecondTab Selector:_close:",
            ],
            prettyActions: ["close tab", "close tab"]
        )

        XCTAssertNil(service.matchingAction(requested: "close tab", record: record))
        XCTAssertEqual(service.matchingAction(requested: record.rawActions[1], record: record), record.rawActions[1])
        let emitted = meaningfulActions(record.rawActions, role: kAXButtonRole as String)
        XCTAssertEqual(emitted, record.rawActions)
        for (selector, rawAction) in zip(emitted, record.rawActions) {
            XCTAssertEqual(service.matchingAction(requested: selector, record: record), rawAction)
        }
    }

    func testAccessibilityRendererMarksCompactGenericClickTargetsAsButtons() {
        XCTAssertTrue(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 1455, y: 218, width: 15, height: 20)
        ))
        XCTAssertTrue(shouldRenderCompactGenericActionTarget(
            role: kAXUnknownRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 1455, y: 245, width: 15, height: 20)
        ))
        XCTAssertTrue(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 10, y: 10, width: 240, height: 120)
        ))
        XCTAssertFalse(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 10, y: 10, width: 117, height: 35),
            hasActionableLinkDescendant: true
        ))
        XCTAssertFalse(shouldRenderCompactGenericActionTarget(
            role: kAXButtonRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 10, y: 10, width: 32, height: 32)
        ))
        XCTAssertFalse(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: false,
            localFrame: CGRect(x: 10, y: 10, width: 32, height: 32)
        ))
        XCTAssertFalse(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 0, y: 0, width: 1920, height: 929)
        ))
        XCTAssertFalse(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: true,
            localFrame: CGRect(x: 0, y: 0, width: 15, height: 0)
        ))
        XCTAssertFalse(shouldRenderCompactGenericActionTarget(
            role: kAXGroupRole as String,
            hasPrimaryClickAction: true,
            localFrame: nil
        ))
    }

    func testAccessibilityRendererOnlyMergesShortTextOnlySiblingRuns() {
        XCTAssertTrue(shouldMergeTextOnlySiblings(["AgentSphere", "17:18", "好的，谢谢"]))
        XCTAssertFalse(shouldMergeTextOnlySiblings(["日期", "时间", "2026年5月7日", "晚餐", "18:00-20:00"]))
        XCTAssertFalse(shouldMergeTextOnlySiblings(["as-next 10min 站会", "12 分钟后", "10:30 - 10:45"]))
        XCTAssertFalse(shouldMergeTextOnlySiblings([
            "📌 3层简卡轻食",
            "自助餐",
            "🐂主荤：香烤鸡腿肉，孜然巴沙鱼",
            "🍡半荤：卤鸡蛋",
            "🥒素菜：剁椒娃娃菜，酸辣金针菇，清炒上海青，清炒胡萝卜，清炒青笋，海带丝拌千张，清炒西葫芦",
            "🍚主食：螺旋意面，蒸玉米，烤面包",
            "🥛饮品：冬瓜蛋花汤",
            "🍒水果：黄瓜",
            "※注意：餐食饮品等仅供职场便利，请勿带离工区",
        ]))
        XCTAssertFalse(shouldMergeTextOnlySiblings(["消息", "126/126"]))
    }

    func testAccessibilityRendererRendersSummariesWithImagesAsChildren() {
        XCTAssertTrue(shouldRenderGenericTextSummaryAsChildren("AgentSphere 17:18 好的，谢谢", summaryImageCount: 1))
        XCTAssertFalse(shouldRenderGenericTextSummaryAsChildren("AgentSphere 17:18 好的，谢谢", summaryImageCount: 0))
        XCTAssertFalse(shouldRenderGenericTextSummaryAsChildren(nil, summaryImageCount: 1))
    }

    func testAccessibilityRendererFiltersScrollToVisibleNoise() {
        XCTAssertEqual(
            meaningfulActions(
                [kAXPressAction as String, "AXScrollToVisible", "AXShowMenu", "AXRaise"],
                role: kAXButtonRole as String
            ),
            ["Raise"]
        )
    }

    func testAccessibilityRendererFiltersImplicitMenuActions() {
        XCTAssertEqual(
            meaningfulActions(
                ["AXCancel", "AXPick", kAXPressAction as String],
                role: kAXMenuBarItemRole as String
            ),
            []
        )
    }

    func testAccessibilityRendererUsesOfficialZoomWindowActionName() {
        XCTAssertEqual(meaningfulActions(["AXZoomWindow"], role: kAXButtonRole as String), ["zoom the window"])
    }

    func testAccessibilityRendererKeepsLinkRoleWhenSuppressingChildren() {
        XCTAssertEqual(
            displayRoleText(
                baseRoleText: "link",
                role: "AXLink",
                title: "[Docs](https://example.com)",
                label: "Docs",
                suppressChildren: true
            ),
            "link"
        )
    }

    func testAccessibilityRendererKeepsMarkdownShapeForSummaryLinks() {
        XCTAssertEqual(
            summaryMarkdownLinkText(
                text: "https://example.com/docs?topic=[agents]",
                url: "https://example.com/docs?topic=%5Bagents%5D"
            ),
            "[https://example.com/docs?topic=\\[agents\\]](https://example.com/docs?topic=%5Bagents%5D)"
        )
        XCTAssertEqual(
            summaryMarkdownLinkText(
                text: "https://example.com/docs",
                url: "https://example.com/docs"
            ),
            "[https://example.com/docs](https://example.com/docs)"
        )
    }

    func testSnapshotTextLimitDefaultsTo500AndSupportsMax() {
        let longText = String(repeating: "候", count: defaultTextLimit + 20)
        let customLimitText = String(repeating: "候", count: 1_020)

        XCTAssertEqual(
            sanitizeText(longText),
            String(longText.prefix(defaultTextLimit)) + "..."
        )
        XCTAssertEqual(
            sanitizeText(customLimitText, textLimit: SnapshotTextLimit(maxCount: 1_000)),
            String(customLimitText.prefix(1_000)) + "..."
        )
        XCTAssertEqual(sanitizeText(longText, textLimit: .max), longText)
    }

    func testAccessibilityRendererSuppressesDuplicateDescriptionForSameTextMarkdownLinks() {
        XCTAssertEqual(
            formattedLabelSegment(
                "https://example.com/docs",
                title: "[https://example.com/docs](https://example.com/docs)",
                linkText: "[https://example.com/docs](https://example.com/docs)"
            ),
            ""
        )
        let longURL = "https://example.com/docs?" + String(repeating: "query=value&", count: 60)
        let truncatedURL = String(longURL.prefix(defaultTextLimit)) + "..."
        XCTAssertEqual(
            formattedLabelSegment(
                longURL,
                title: "[\(truncatedURL)](\(truncatedURL))",
                linkText: "[\(truncatedURL)](\(truncatedURL))"
            ),
            ""
        )
    }

    func testAccessibilityRendererFormatsPlaceholderSegment() {
        XCTAssertEqual(
            formattedPlaceholderSegment(
                "Ask Google or type a URL",
                title: nil,
                label: "Address and search bar",
                value: "example.com",
                precedingSegments: [" Description: Address and search bar", " Value: example.com"]
            ),
            ", Placeholder: Ask Google or type a URL"
        )
        XCTAssertEqual(
            formattedPlaceholderSegment(
                "Search mail",
                title: nil,
                label: "Search mail",
                value: nil,
                precedingSegments: []
            ),
            ""
        )
    }

    func testBlockingAsyncBridgeTimesOutScreenshotWork() {
        XCTAssertThrowsError(
            try BlockingAsyncBridge.run(timeout: 0.01) {
                try await Task.sleep(nanoseconds: 200_000_000)
                return "late"
            }
        ) { error in
            XCTAssertTrue(
                (error as? ComputerUseError)?.errorDescription?.contains("timed out") == true
            )
        }
    }

    func testComputerUseErrorsFormatLikeToolText() {
        XCTAssertEqual(ComputerUseError.appNotFound("Sublime Text").errorDescription, #"appNotFound("Sublime Text")"#)
        XCTAssertTrue(ComputerUseError.appNotFound("Sublime Text").toolResultIsError)
        XCTAssertTrue(ComputerUseError.invalidArguments("bad").toolResultIsError)
    }

    func testNoWindowErrorMessageMatchesOfficialShape() {
        XCTAssertEqual(computerUseNoWindowFoundMessage, "Apple event error -10005: cgWindowNotFound")
        XCTAssertEqual(
            ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage).errorDescription,
            "Apple event error -10005: cgWindowNotFound"
        )
    }

    func testAppSafetyPolicyDoesNotBlockNonPasswordApps() {
        XCTAssertFalse(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.googlecode.iterm2"))
        XCTAssertFalse(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.openai.atlas.beta"))
        XCTAssertFalse(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.apple.SecurityAgent"))
    }

    func testAppSafetyPolicyKeepsPasswordManagerBlocks() {
        XCTAssertTrue(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.1password.1password"))
        XCTAssertTrue(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.bitwarden.desktop"))
        XCTAssertTrue(AppSafetyPolicy.isBlocked(bundleIdentifier: "me.proton.pass.electron"))
    }

    func testVisualCursorEnvFlagDefaultsToEnabled() {
        XCTAssertTrue(visualCursorEnabled(environment: [:]))
        XCTAssertTrue(visualCursorEnabled(environment: ["OPEN_COMPUTER_USE_VISUAL_CURSOR": "1"]))
        XCTAssertFalse(visualCursorEnabled(environment: ["OPEN_COMPUTER_USE_VISUAL_CURSOR": "0"]))
        XCTAssertFalse(visualCursorEnabled(environment: ["OPEN_COMPUTER_USE_VISUAL_CURSOR": "false"]))
    }

    func testInputFallbackDebugFlagDefaultsToDisabled() {
        XCTAssertFalse(inputFallbackDebugEnabled(environment: [:]))
        XCTAssertTrue(inputFallbackDebugEnabled(environment: ["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS": "1"]))
        XCTAssertTrue(inputFallbackDebugEnabled(environment: ["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS": "true"]))
        XCTAssertFalse(inputFallbackDebugEnabled(environment: ["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS": "0"]))
        XCTAssertFalse(inputFallbackDebugEnabled(environment: ["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS": "off"]))
    }

    func testGlobalPointerFallbackFlagDefaultsToDisabled() {
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: [:]))
        XCTAssertTrue(globalPointerFallbacksEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]))
        XCTAssertTrue(globalPointerFallbacksEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "yes"]))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "0"]))
        XCTAssertFalse(globalPointerFallbacksEnabled(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "false"]))
    }

    func testActionReadBackFlagDefaultsToEnabled() {
        XCTAssertTrue(actionReadBackEnabled(environment: [:]))
        XCTAssertTrue(actionReadBackEnabled(environment: ["OPEN_COMPUTER_USE_ACTION_READ_BACK": "1"]))
        XCTAssertFalse(actionReadBackEnabled(environment: ["OPEN_COMPUTER_USE_ACTION_READ_BACK": "0"]))
        XCTAssertFalse(actionReadBackEnabled(environment: ["OPEN_COMPUTER_USE_ACTION_READ_BACK": " off "]))
    }

    func testDragStepCountScalesWithDistanceAndClampsToBounds() {
        XCTAssertEqual(InputSimulation.dragStepCount(from: .zero, to: .zero), 10)
        XCTAssertEqual(InputSimulation.dragStepCount(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 8, y: 0)), 10)
        XCTAssertEqual(InputSimulation.dragStepCount(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0)), 50)
        XCTAssertEqual(InputSimulation.dragStepCount(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 5000, y: 0)), 60)
    }

    func testNeedsDragEventNumberGatesOnRecentMacOS() {
        // Older macOS ignores the gesture event number; 26+ needs it (codex#43047).
        XCTAssertFalse(InputSimulation.needsDragEventNumber(majorVersion: 14))
        XCTAssertFalse(InputSimulation.needsDragEventNumber(majorVersion: 15))
        XCTAssertFalse(InputSimulation.needsDragEventNumber(majorVersion: 25))
        XCTAssertTrue(InputSimulation.needsDragEventNumber(majorVersion: 26))
        XCTAssertTrue(InputSimulation.needsDragEventNumber(majorVersion: 27))
    }

    func testDragDeliveryPathFollowsGlobalPointerGate() {
        XCTAssertEqual(dragDeliveryPath(environment: [:]), .appPost)
        XCTAssertEqual(dragDeliveryPath(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "0"]), .appPost)
        XCTAssertEqual(dragDeliveryPath(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]), .global)
        XCTAssertEqual(dragDeliveryPath(environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": " True "]), .global)
    }

    func testDragDeliveryNoteExplainsWhyDefaultPathCannotDriveWindowServerDrags() {
        let appPostNote = dragDeliveryNote(for: .appPost)
        XCTAssertTrue(appPostNote.hasPrefix("Drag delivered via app_post"))
        XCTAssertTrue(appPostNote.contains("system pointer did not move"))
        XCTAssertTrue(appPostNote.contains("window moves"))
        XCTAssertTrue(appPostNote.contains("text selection"))
        XCTAssertTrue(appPostNote.contains("Finder drag-and-drop"))
        XCTAssertTrue(appPostNote.contains("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1"))

        let globalNote = dragDeliveryNote(for: .global)
        XCTAssertTrue(globalNote.hasPrefix("Drag delivered via global pointer path"))
        XCTAssertTrue(globalNote.contains("real pointer may have moved"))
    }

    func testDragDeliveryNoteIsInsertedAfterSnapshotTextAndBeforeScreenshot() {
        let snapshotText = "App=com.example.app (pid 42)\nWindow: \"Example\", App: Example."
        let result = ToolCallResult(content: [.text(snapshotText), .pngImage(Data([0x89, 0x50, 0x4E, 0x47]))])

        let annotated = appendingDragDeliveryNote(to: result, path: .appPost)

        XCTAssertEqual(annotated.primaryText, snapshotText)
        XCTAssertEqual(annotated.content.count, 3)
        XCTAssertEqual(annotated.content[1].dictionary["type"] as? String, "text")
        XCTAssertEqual(annotated.content[1].dictionary["text"] as? String, dragDeliveryNote(for: .appPost))
        XCTAssertEqual(annotated.content[2].dictionary["type"] as? String, "image")
        XCTAssertFalse(annotated.isError)
    }

    func testDragDeliveryNoteIsAppendedWhenResultHasNoScreenshot() {
        let annotated = appendingDragDeliveryNote(to: .text("App=com.example.app (pid 42)"), path: .global)

        XCTAssertEqual(annotated.primaryText, "App=com.example.app (pid 42)")
        XCTAssertEqual(annotated.content.count, 2)
        XCTAssertEqual(annotated.content[1].dictionary["text"] as? String, dragDeliveryNote(for: .global))
    }

    func testClickMethodDefaultsToAutoAndNormalizesExplicitValues() throws {
        XCTAssertEqual(try parseClickMethod(nil), .auto)
        XCTAssertEqual(try parseClickMethod(" AUTO "), .auto)
        XCTAssertEqual(try parseClickMethod("Accessibility"), .accessibility)
        XCTAssertEqual(try parseClickMethod(" APP_POST "), .appPost)
        XCTAssertEqual(try parseClickMethod(" SKY_CLICK "), .skyClick)
        XCTAssertEqual(try parseClickMethod("GLOBAL"), .global)
    }

    func testOnlySkyClickUsesReadOnlyActionSnapshotRefresh() {
        XCTAssertEqual(clickActionSnapshotRecoveryPolicy(for: .skyClick), .readOnly)

        for method in ClickMethod.allCases where method != .skyClick {
            XCTAssertEqual(
                clickActionSnapshotRecoveryPolicy(for: method),
                .allowActivation
            )
        }
    }

    func testFixtureStateFocusProbeFieldsRemainBackwardCompatible() throws {
        let legacyPayload = #"""
        {
          "windowTitle": "Legacy Fixture",
          "windowBounds": {"x": 1, "y": 2, "width": 3, "height": 4},
          "focusedIdentifier": null,
          "elements": []
        }
        """#

        let state = try JSONDecoder().decode(
            FixtureAppState.self,
            from: Data(legacyPayload.utf8)
        )
        XCTAssertNil(state.processIdentifier)
        XCTAssertNil(state.isActive)
        XCTAssertNil(state.isKeyWindow)
        XCTAssertNil(state.activationLossCount)
        XCTAssertNil(state.keyWindowLossCount)
    }

    func testClickMethodRejectsUnknownValues() {
        for value in ["physical", "targeted"] {
            XCTAssertThrowsError(try parseClickMethod(value)) { error in
                XCTAssertEqual(
                    (error as? ComputerUseError)?.errorDescription,
                    "Invalid click_method '\(value)'. Expected one of: auto, accessibility, app_post, sky_click, global"
                )
            }
        }
    }

    func testAccessibilityClickMethodRequiresElementIndex() {
        XCTAssertThrowsError(
            try validateClickMethod(.accessibility, hasElementIndex: false, environment: [:])
        ) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "click_method 'accessibility' requires element_index"
            )
        }

        XCTAssertNoThrow(
            try validateClickMethod(.accessibility, hasElementIndex: true, environment: [:])
        )
    }

    func testGlobalClickMethodRequiresExplicitPointerAuthorization() {
        XCTAssertThrowsError(
            try validateClickMethod(.global, hasElementIndex: false, environment: [:])
        ) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
            )
        }

        XCTAssertNoThrow(
            try validateClickMethod(
                .global,
                hasElementIndex: false,
                environment: ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1"]
            )
        )
    }

    func testSkyClickArgumentsRequireLeftButtonAndSingleOrDoubleClick() throws {
        XCTAssertNoThrow(
            try validateSkyClickArguments(method: .skyClick, mouseButton: " LEFT ", clickCount: 1)
        )
        XCTAssertNoThrow(
            try validateSkyClickArguments(method: .skyClick, mouseButton: "left", clickCount: 2)
        )
        XCTAssertNoThrow(
            try validateSkyClickArguments(method: .appPost, mouseButton: "right", clickCount: 5)
        )

        XCTAssertThrowsError(
            try validateSkyClickArguments(method: .skyClick, mouseButton: "right", clickCount: 1)
        ) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "click_method 'sky_click' only supports mouse_button 'left'"
            )
        }
        XCTAssertThrowsError(
            try validateSkyClickArguments(method: .skyClick, mouseButton: "left", clickCount: 3)
        ) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "click_method 'sky_click' supports click_count 1 or 2"
            )
        }
    }

    func testSkyClickRecipeIncludesMovePrimerAndTargetPairs() throws {
        let single = try skyClickEventRecipe(clickCount: 1)
        XCTAssertEqual(single.count, 5)
        XCTAssertEqual(single.map(\.kind), [.moved, .down, .up, .down, .up])
        XCTAssertEqual(single.map(\.pointKind), [.target, .primer, .primer, .target, .target])
        XCTAssertEqual(single.map(\.phase), [2, 1, 2, 3, 3])
        XCTAssertEqual(single.map(\.clickState), [0, 1, 1, 1, 1])

        let double = try skyClickEventRecipe(clickCount: 2)
        XCTAssertEqual(double.count, 7)
        XCTAssertEqual(double.suffix(4).map(\.clickState), [1, 1, 2, 2])
        XCTAssertEqual(double[4].delayAfter, 0.080, accuracy: 0.000_001)
        XCTAssertEqual(double.last?.delayAfter, 0)
    }

    func testSkyClickRecipeRejectsUnsupportedClickCounts() {
        for count in [0, 3] {
            XCTAssertThrowsError(try skyClickEventRecipe(clickCount: count)) { error in
                XCTAssertEqual(
                    (error as? ComputerUseError)?.errorDescription,
                    "click_method 'sky_click' supports click_count 1 or 2"
                )
            }
        }
    }

    func testSkyClickWindowValidationRequiresMatchingOwner() {
        let matching: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: UInt32(321)),
            kCGWindowOwnerPID as String: NSNumber(value: Int32(1234)),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
        ]
        XCTAssertTrue(
            skyClickWindowMatchesTarget(windowInfo: [matching], windowID: 321, pid: 1234)
        )
        XCTAssertFalse(
            skyClickWindowMatchesTarget(windowInfo: [matching], windowID: 322, pid: 1234)
        )
        XCTAssertFalse(
            skyClickWindowMatchesTarget(windowInfo: [matching], windowID: 321, pid: 1235)
        )
    }

    func testWindowLooksUnoccludedSamplesAGrid() {
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(windowLooksUnoccluded(bounds: bounds, coveringBounds: []))
        XCTAssertFalse(windowLooksUnoccluded(bounds: bounds, coveringBounds: [bounds.insetBy(dx: -10, dy: -10)]))
        XCTAssertFalse(windowLooksUnoccluded(bounds: bounds, coveringBounds: [
            CGRect(x: 0, y: 0, width: 300, height: 1000), CGRect(x: 300, y: 0, width: 1000, height: 1000),
        ]), "two windows that jointly cover the target count as occlusion")
        XCTAssertTrue(windowLooksUnoccluded(bounds: bounds, coveringBounds: [CGRect(x: 100, y: 100, width: 360, height: 300)]), "an exposed strip keeps it visible")
        XCTAssertFalse(windowLooksUnoccluded(bounds: .zero, coveringBounds: []))
    }

    func testSkyLightCapabilityReportsMissingSymbols() {
        XCTAssertEqual(
            SkyLightSPICapability(missingSymbols: []).unavailableReason,
            "available"
        )
        XCTAssertEqual(
            SkyLightSPICapability(missingSymbols: ["SLEventPostToPid"]).unavailableReason,
            "missing private click symbols: SLEventPostToPid"
        )
    }

    func testSkyLightActivationRecordEncodesWindowAndFocusState() {
        let focused = skyLightActivationRecord(windowID: 0x1234_5678, focused: true)
        XCTAssertEqual(focused.count, 0xF8)
        XCTAssertEqual(focused[0x04], 0xF8)
        XCTAssertEqual(focused[0x08], 0x0D)
        XCTAssertEqual(Array(focused[0x3C...0x3F]), [0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(focused[0x8A], 0x01)

        let defocused = skyLightActivationRecord(windowID: 42, focused: false)
        XCTAssertEqual(defocused[0x8A], 0x02)
    }

    func testSkyLightSyntheticFocusPlanOnlyAddressesTarget() {
        let targetPSN = [UInt8](repeating: 7, count: 8)
        let plan = skyLightSyntheticTargetFocusPlan(
            targetPSN: targetPSN,
            targetWindowID: 321
        )

        XCTAssertEqual(
            plan,
            SkyLightSyntheticFocusPlan(
                activateTarget: SkyLightActivationCommand(
                    psn: targetPSN,
                    windowID: 321,
                    focused: true
                ),
                deactivateTarget: SkyLightActivationCommand(
                    psn: targetPSN,
                    windowID: 321,
                    focused: false
                )
            )
        )
    }

    func testSkyLightKeyWindowRecordsFollowYabaiLayout() {
        let records = skyLightKeyWindowRecords(windowID: 0x1234_5678)
        XCTAssertEqual(records.map(\.count), [0xF8, 0xF8])
        XCTAssertEqual(records.map { $0[0x08] }, [0x01, 0x02])
        for record in records {
            XCTAssertEqual(record[0x04], 0xF8)
            XCTAssertEqual(record[0x3A], 0x10)
            XCTAssertEqual(Array(record[0x3C...0x3F]), [0x78, 0x56, 0x34, 0x12])
            XCTAssertEqual(Array(record[0x20..<0x30]), [UInt8](repeating: 0xFF, count: 0x10))
            XCTAssertEqual(record[0x8A], 0, "key-window records must not carry the activation focus marker")
        }
    }

    func testSkyMenuKeyEquivalentOnlyCoversCommandCharacterChords() throws {
        XCTAssertEqual(
            skyMenuKeyEquivalent(for: try KeyPressParser.parse("cmd+a")),
            SkyMenuKeyEquivalent(character: "A", modifiers: 0)
        )
        XCTAssertEqual(
            skyMenuKeyEquivalent(for: try KeyPressParser.parse("cmd+shift+option+ctrl+z")),
            SkyMenuKeyEquivalent(character: "Z", modifiers: 7)
        )
        XCTAssertNil(skyMenuKeyEquivalent(for: try KeyPressParser.parse("shift+a")), "non-command chords are key events")
        XCTAssertNil(skyMenuKeyEquivalent(for: try KeyPressParser.parse("cmd+shift+left")), "navigation chords are key bindings, not menu items")
        XCTAssertNil(skyMenuKeyEquivalent(for: try KeyPressParser.parse("return")))
    }

    func testSkyMenuItemMatchingIsCaseInsensitiveAndSkipsDisabledItems() {
        let selectAll = SkyMenuKeyEquivalent(character: "A", modifiers: 0)
        XCTAssertTrue(skyMenuItemMatches(cmdChar: "a", cmdModifiers: nil, enabled: nil, equivalent: selectAll))
        XCTAssertTrue(skyMenuItemMatches(cmdChar: "A", cmdModifiers: 0, enabled: true, equivalent: selectAll))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "A", cmdModifiers: 1, enabled: true, equivalent: selectAll))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: "A", cmdModifiers: 0, enabled: false, equivalent: selectAll))
        XCTAssertFalse(skyMenuItemMatches(cmdChar: nil, cmdModifiers: 0, enabled: true, equivalent: selectAll))
    }

    func testSkyKeyWindowValidationAllowsOffScreenWindowsOfTheSameOwner() {
        let offScreen: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: UInt32(321)),
            kCGWindowOwnerPID as String: NSNumber(value: Int32(1234)),
            kCGWindowIsOnscreen as String: NSNumber(value: false),
        ]
        XCTAssertTrue(skyKeyWindowMatchesTarget(windowInfo: [offScreen], windowID: 321, pid: 1234))
        XCTAssertFalse(skyKeyWindowMatchesTarget(windowInfo: [offScreen], windowID: 321, pid: 1235))
        XCTAssertFalse(skyKeyWindowMatchesTarget(windowInfo: [offScreen], windowID: 322, pid: 1234))
        XCTAssertTrue(skyClickWindowMatchesTarget(windowInfo: [offScreen], windowID: 321, pid: 1234), "sky_click also accepts covered or other-Space windows")
    }

    func testLazyWebAccessibilityDetectionUsesShippedFrameworks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-lazy-ax-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chromium = root.appendingPathComponent("Chromium.app/Contents/Frameworks/Chromium Framework.framework")
        try FileManager.default.createDirectory(at: chromium, withIntermediateDirectories: true)
        let native = root.appendingPathComponent("Native.app/Contents/Frameworks/Sparkle.framework")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        XCTAssertTrue(appHasLazyWebAccessibility(bundleURL: root.appendingPathComponent("Chromium.app")))
        XCTAssertFalse(appHasLazyWebAccessibility(bundleURL: root.appendingPathComponent("Native.app")))
        XCTAssertFalse(appHasLazyWebAccessibility(bundleURL: nil))
    }

    func testWindowPlacementParsingAndAgentDisplayGeometry() throws {
        XCTAssertEqual(try parseWindowPlacement(nil), .keep)
        XCTAssertEqual(try parseWindowPlacement(" Agent_Display "), .agentDisplay)
        XCTAssertEqual(try parseWindowPlacement("restore"), .restore)
        XCTAssertThrowsError(try parseWindowPlacement("park")) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "Invalid window_placement 'park'. Expected one of: keep, agent_display, restore"
            )
        }

        let display = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(agentDisplayPlacement(windowSize: CGSize(width: 600, height: 420), displayBounds: display), CGPoint(x: 1552, y: 40))
        let huge = agentDisplayPlacement(windowSize: CGSize(width: 4000, height: 3000), displayBounds: display)
        XCTAssertEqual(huge, CGPoint(x: 1512, y: 0), "oversized windows are pinned to the display origin")
        XCTAssertTrue(display.contains(huge))
        for name in ["get_app_state"] {
            let tool = ToolDefinitions.all.first { $0.name == name }
            let properties = tool?.inputSchema["properties"] as? [String: Any]
            XCTAssertEqual((properties?["window_placement"] as? [String: Any])?["enum"] as? [String], ["keep", "agent_display", "restore"])
        }
    }

    func testBackgroundInputTimingDefaultsKeepCompatibilityMargins() {
        XCTAssertEqual(InputTiming.typeChunkDelayDefaultMilliseconds, 20)
        XCTAssertEqual(InputTiming.pressKeySettleDefaultMilliseconds, 100)
        XCTAssertEqual(SkyKeyboardDispatcher.keyWindowFallbackSettleDefaultMilliseconds, 10)
        XCTAssertEqual(SkyKeyboardDispatcher.releaseSettleDefaultMilliseconds, 10)
        XCTAssertEqual(
            InputTiming.milliseconds("OCU_TEST_TIMING", default: 20, environment: [:]),
            0.020,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            InputTiming.milliseconds("OCU_TEST_TIMING", default: 20, environment: ["OCU_TEST_TIMING": "7.5"]),
            0.0075,
            accuracy: 0.000_001
        )
    }

    func testAgentDisplayRestoreGeometryUsesATolerance() {
        let original = CGPoint(x: 200, y: 300)
        XCTAssertTrue(AgentDisplay.isRestored(frame: CGRect(x: 200.5, y: 299.5, width: 600, height: 420), to: original))
        XCTAssertFalse(AgentDisplay.isRestored(frame: CGRect(x: 202, y: 300, width: 600, height: 420), to: original))
    }

    func testOcclusionKeepAliveRestoresPriorStateAndCanRetryFailures() {
        final class FakeOcclusionSPI: WindowOcclusionControlling {
            let occlusionCapability = SkyLightSPICapability(missingSymbols: [], feature: "occlusion")
            var states: [CGWindowID: Bool] = [101: true, 102: false]
            var failedRestores: Set<CGWindowID> = [101]
            var calls: [CGWindowID: Int] = [:]

            func setWindowOcclusionNotificationsEnabled(_ enabled: Bool, windowID: CGWindowID) throws -> Bool {
                calls[windowID, default: 0] += 1
                let previous = states[windowID] ?? true
                if calls[windowID, default: 0] > 1, failedRestores.remove(windowID) != nil {
                    throw ComputerUseError.message("injected restore failure")
                }
                states[windowID] = enabled
                return previous
            }
        }

        let keepAlive = WindowOcclusionKeepAlive()
        let spi = FakeOcclusionSPI()
        let visibleBounds = CGRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertTrue(keepAlive.keepVisible(windowID: 101, bounds: visibleBounds, spi: spi))
        XCTAssertTrue(keepAlive.keepVisible(windowID: 102, bounds: visibleBounds, spi: spi))
        XCTAssertEqual(spi.states[101], false)
        XCTAssertEqual(spi.states[102], false)

        keepAlive.releaseAll(spi: spi)
        XCTAssertTrue(keepAlive.isPinned(windowID: 101), "failed restores must remain retryable")
        XCTAssertFalse(keepAlive.isPinned(windowID: 102))
        XCTAssertEqual(spi.states[102], false, "restore the original disabled state, not always true")

        keepAlive.releaseAll(spi: spi)
        XCTAssertFalse(keepAlive.isPinned(windowID: 101))
        XCTAssertEqual(spi.states[101], true)
    }

    func testKeyMethodParsingAndPolicy() throws {
        XCTAssertEqual(try parseKeyMethod(nil), .auto)
        XCTAssertEqual(try parseKeyMethod(" SKY_KEY "), .skyKey)
        XCTAssertThrowsError(try parseKeyMethod("global")) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "Invalid key_method 'global'. Expected one of: auto, sky_key"
            )
        }
        XCTAssertEqual(keyActionSnapshotRecoveryPolicy(for: .skyKey), .readOnly)
        XCTAssertEqual(keyActionSnapshotRecoveryPolicy(for: .auto), .allowActivation)
    }

    func testKeyboardToolSchemasExposeKeyMethod() {
        for name in ["type_text", "press_key"] {
            let tool = ToolDefinitions.all.first { $0.name == name }
            let properties = tool?.inputSchema["properties"] as? [String: Any]
            let keyMethod = properties?["key_method"] as? [String: Any]
            XCTAssertEqual(keyMethod?["enum"] as? [String], ["auto", "sky_key"], name)
        }
    }

    func testSkyLightRuntimeSPIProbeCanStampEventWithoutPosting() throws {
        let spi = SkyLightSPI.shared
        guard spi.capability.isAvailable else {
            throw XCTSkip("SkyLight SPI unavailable: \(spi.capability.unavailableReason)")
        }
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: 10, y: 20),
                mouseButton: .left
            )
        else {
            return XCTFail("Failed to create a probe CGEvent")
        }

        try spi.setIntegerField(event, field: 1, value: 2)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 2)
        XCTAssertNoThrow(
            try spi.setWindowLocation(event, point: CGPoint(x: 3, y: 4))
        )
    }

    func testSetValueAttributeGateMatchesOfficialSettableBoundary() throws {
        XCTAssertTrue(try setValueAttributeIsSettable(result: .success, settable: true, attribute: kAXValueAttribute))
        XCTAssertFalse(try setValueAttributeIsSettable(result: .success, settable: false, attribute: kAXValueAttribute))
        XCTAssertEqual(nonSettableSetValueErrorMessage, "Cannot set a value for an element that is not settable")

        XCTAssertThrowsError(
            try setValueAttributeIsSettable(result: .attributeUnsupported, settable: false, attribute: kAXValueAttribute)
        ) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "AXUIElementIsAttributeSettable(AXValue) failed with -25205"
            )
        }
    }

    func testSetPositionReadBackFailsOnlyWhenNothingMoved() {
        let before = CGRect(x: 100, y: 200, width: 300, height: 40)
        let moved = CGPoint(x: 160, y: 200)
        // applied, within a point of the request
        XCTAssertEqual(axFrameReadBack(before: before, after: CGRect(x: 160.4, y: 200, width: 300, height: 40), origin: moved, size: nil), .applied)
        // still where it was: the only failure
        XCTAssertEqual(axFrameReadBack(before: before, after: before, origin: moved, size: nil), .unchanged)
        // the app snapped it to its grid, or kept a window below the menu bar
        XCTAssertEqual(axFrameReadBack(before: before, after: CGRect(x: 150, y: 200, width: 300, height: 40), origin: moved, size: nil), .adjusted)
        XCTAssertEqual(axFrameReadBack(before: before, after: nil, origin: moved, size: nil), .unverifiable)
        XCTAssertEqual(axFrameReadBack(before: nil, after: before, origin: moved, size: nil), .adjusted)
        // a request for where it already is succeeds
        XCTAssertEqual(axFrameReadBack(before: before, after: before, origin: before.origin, size: nil), .applied)
        // only the written part is compared: a size write ignores the position, and back
        let wider = CGSize(width: 400, height: 40)
        XCTAssertEqual(axFrameReadBack(before: before, after: CGRect(x: 0, y: 0, width: 400, height: 40), origin: nil, size: wider), .applied)
        XCTAssertEqual(axFrameReadBack(before: before, after: CGRect(x: 0, y: 0, width: 300, height: 40), origin: nil, size: wider), .unchanged)
        XCTAssertEqual(axFrameReadBack(before: before, after: CGRect(x: 160, y: 200, width: 999, height: 9), origin: moved, size: nil), .applied)
    }

    func testSetPositionValidatesArgumentsBeforeReadingTheApp() {
        let dispatcher = ComputerUseToolDispatcher()
        func error(_ arguments: [String: Any]) -> String? {
            let result = dispatcher.callToolAsResult(name: "set_position", arguments: (["app": "No Such App 4fd1", "element_index": "3"] as [String: Any]).merging(arguments) { $1 })
            XCTAssertTrue(result.isError)
            return result.primaryText
        }
        XCTAssertEqual(error(["y": 10]), "Missing required argument: x")
        XCTAssertEqual(error(["x": 10, "y": 10, "width": 50]), #"invalidArguments("set_position requires width and height together")"#)
        XCTAssertEqual(error(["x": 10, "y": 10, "width": 50, "height": 0]), #"invalidArguments("set_position width and height must be positive numbers")"#)
        XCTAssertEqual(error(["x": Double.infinity, "y": 10]), #"invalidArguments("set_position requires finite x and y")"#)
    }

    func testMakeVisualCursorTargetUsesWindowRelativeElementCenter() {
        let screenMappings = [
            VisualCursorScreenMapping(
                screenStateFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                appKitFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
            ),
        ]
        let target = makeVisualCursorTarget(
            localFrame: CGRect(x: 24, y: 32, width: 120, height: 48),
            windowBounds: CGRect(x: 400, y: 220, width: 900, height: 640),
            targetWindowID: 321,
            targetWindowLayer: 8,
            screenMappings: screenMappings
        )

        // The target also carries the anchor: the element centre relative to
        // the window frame it was derived from, which is what lets the overlay
        // follow the window if it moves before the action lands.
        XCTAssertEqual(
            target,
            VisualCursorTarget(
                point: CGPoint(x: 484, y: 724),
                window: CursorTargetWindow(windowID: 321, layer: 8),
                anchor: CursorRestingAnchor(
                    windowID: 321,
                    layer: 8,
                    windowLocalPoint: CGPoint(x: 84, y: 56),
                    windowBounds: CGRect(x: 400, y: 220, width: 900, height: 640)
                )
            )
        )
    }

    func testMakeVisualCursorTargetReturnsNilWithoutWindowBounds() {
        XCTAssertNil(
            makeVisualCursorTarget(
                localFrame: CGRect(x: 24, y: 32, width: 120, height: 48),
                windowBounds: nil,
                targetWindowID: 321,
                targetWindowLayer: 8
            )
        )
    }

    func testVisualCursorAppKitPointConvertsScreenStateYDownCoordinates() {
        let point = visualCursorAppKitPoint(
            fromScreenStatePoint: CGPoint(x: 2415, y: 181),
            screenMappings: [
                VisualCursorScreenMapping(
                    screenStateFrame: CGRect(x: 0, y: 0, width: 3024, height: 1964),
                    appKitFrame: CGRect(x: 0, y: 0, width: 3024, height: 1964)
                ),
            ]
        )

        XCTAssertEqual(point, CGPoint(x: 2415, y: 1783))
    }

    func testInputEventPointKeepsCoreGraphicsScreenStateCoordinates() {
        let point = inputEventPoint(
            fromScreenStatePoint: CGPoint(x: -1311, y: 701),
            screenMappings: [
                VisualCursorScreenMapping(
                    screenStateFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                    appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
                ),
                VisualCursorScreenMapping(
                    screenStateFrame: CGRect(x: -1512, y: 458, width: 1512, height: 982),
                    appKitFrame: CGRect(x: -1512, y: 0, width: 1512, height: 982)
                ),
            ]
        )

        XCTAssertEqual(point, CGPoint(x: -1311, y: 701))
    }

    func testScreenshotPixelScaleUsesRetinaSizedImageAgainstWindowBounds() {
        let scale = screenshotPixelScale(
            screenshotPixelSize: CGSize(width: 2048, height: 1266),
            windowBounds: CGRect(x: 1938, y: 236, width: 1024, height: 633)
        )

        XCTAssertEqual(scale.width, 2, accuracy: 0.0001)
        XCTAssertEqual(scale.height, 2, accuracy: 0.0001)
    }

    func testScreenshotPixelScaleStaysAtOneForUnscaledDisplays() {
        let scale = screenshotPixelScale(
            screenshotPixelSize: CGSize(width: 1024, height: 633),
            windowBounds: CGRect(x: 1938, y: 236, width: 1024, height: 633)
        )

        XCTAssertEqual(scale.width, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.height, 1, accuracy: 0.0001)
    }

    func testScreenshotPixelToWindowPointConvertsScreenshotPixelsBackToWindowPoints() {
        let point = screenshotPixelToWindowPoint(
            CGPoint(x: 1060, y: 790),
            screenshotPixelSize: CGSize(width: 2048, height: 1266),
            windowBounds: CGRect(x: 1938, y: 236, width: 1024, height: 633)
        )

        XCTAssertEqual(point.x, 530, accuracy: 0.0001)
        XCTAssertEqual(point.y, 395, accuracy: 0.0001)
    }

    func testScreenshotPixelToWindowPointKeepsCoordinatesOnUnscaledDisplays() {
        let point = screenshotPixelToWindowPoint(
            CGPoint(x: 530, y: 395),
            screenshotPixelSize: CGSize(width: 1024, height: 633),
            windowBounds: CGRect(x: 1938, y: 236, width: 1024, height: 633)
        )

        XCTAssertEqual(point, CGPoint(x: 530, y: 395))
    }

    func testScreenshotPixelToWindowPointFallsBackToIdentityWithoutImageSize() {
        let point = screenshotPixelToWindowPoint(
            CGPoint(x: 530, y: 395),
            screenshotPixelSize: nil,
            windowBounds: CGRect(x: 1938, y: 236, width: 1024, height: 633)
        )

        XCTAssertEqual(point, CGPoint(x: 530, y: 395))
    }

    func testWindowCapturePrefersFrontmostOverHintWhenModalOverlapsHintedWindow() {
        let main = WindowCaptureCandidate(
            windowID: 1,
            layer: 0,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            title: "Nomi",
            area: 480_000,
            frontToBackIndex: 1
        )
        let openPanel = WindowCaptureCandidate(
            windowID: 2,
            layer: 0,
            bounds: CGRect(x: 120, y: 180, width: 880, height: 448),
            title: "Open",
            area: 394_240,
            frontToBackIndex: 0
        )

        let selected = preferredWindowCaptureCandidate([openPanel, main], titleHint: "Nomi")

        XCTAssertEqual(selected?.windowID, openPanel.windowID)
    }

    func testWindowCaptureKeepsHintedWindowWhenFrontmostDoesNotOverlap() {
        let main = WindowCaptureCandidate(
            windowID: 1,
            layer: 0,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            title: "Nomi",
            area: 480_000,
            frontToBackIndex: 1
        )
        let other = WindowCaptureCandidate(
            windowID: 2,
            layer: 0,
            bounds: CGRect(x: 1_200, y: 100, width: 400, height: 300),
            title: "Utility",
            area: 120_000,
            frontToBackIndex: 0
        )

        let selected = preferredWindowCaptureCandidate([other, main], titleHint: "Nomi")

        XCTAssertEqual(selected?.windowID, main.windowID)
    }

    func testListTraversalPrefersVisibleChildrenAndReadsContents() {
        let attributes = childTraversalAttributes(
            role: kAXListRole as String,
            hasRows: false,
            hasVisibleChildren: true
        )

        XCTAssertFalse(attributes.contains(kAXChildrenAttribute))
        XCTAssertTrue(attributes.contains("AXContents"))
        XCTAssertTrue(attributes.contains("AXVisibleChildren"))
    }

    func testCursorWindowGeometryAnchorsTipPosition() {
        let geometry = CursorWindowGeometry(
            windowSize: CGSize(width: 128, height: 128),
            tipAnchor: CGPoint(x: 44, y: 88)
        )
        let tipPosition = CGPoint(x: 1200, y: 800)

        XCTAssertEqual(geometry.origin(forTipPosition: tipPosition), CGPoint(x: 1156, y: 712))
        XCTAssertEqual(geometry.tipPosition(forOrigin: CGPoint(x: 1156, y: 712)), tipPosition)
    }

    func testSoftwareCursorGlyphMetricsMatchRuntimeProceduralCalibration() {
        XCTAssertEqual(SoftwareCursorGlyphMetrics.windowSize, CGSize(width: 126, height: 126))
        XCTAssertEqual(SoftwareCursorGlyphMetrics.tipAnchor.x, 60.35, accuracy: 0.01)
        XCTAssertEqual(SoftwareCursorGlyphMetrics.tipAnchor.y, 70.3, accuracy: 0.01)
        XCTAssertEqual(SoftwareCursorGlyphMetrics.referenceImageResourceName, "official-software-cursor-window-252")
    }

    func testSoftwareCursorGlyphLoadsCursorMotionReferenceImage() throws {
        let image = try XCTUnwrap(loadReferenceCursorWindowImage())
        let bitmap = try XCTUnwrap(image.representations.first)

        XCTAssertEqual(bitmap.pixelsWide, 252)
        XCTAssertEqual(bitmap.pixelsHigh, 252)
    }

    func testSoftwareCursorGlyphArtworkNeutralHeadingMatchesCursorMotionBaseline() {
        let correctedNeutralHeading = SoftwareCursorGlyphMetrics.proceduralContourNeutralHeading
            - SoftwareCursorGlyphMetrics.pointerArtworkRotation

        XCTAssertEqual(
            correctedNeutralHeading,
            SoftwareCursorGlyphMetrics.targetNeutralHeading,
            accuracy: 0.001
        )
        XCTAssertEqual(SoftwareCursorGlyphMetrics.targetNeutralHeading, -(3 * CGFloat.pi / 4), accuracy: 0.001)
    }

    func testSoftwareCursorGlyphConvertsScreenStateToAppKitDrawingState() {
        let screenState = SoftwareCursorGlyphRenderState(
            rotation: .pi / 3,
            cursorBodyOffset: CGVector(dx: 2, dy: -4),
            fogOffset: CGVector(dx: -3, dy: 5),
            fogOpacity: 0.2,
            fogScale: 1.1,
            clickProgress: 0.6
        )

        let drawingState = screenState.appKitDrawingState

        XCTAssertEqual(drawingState.rotation, -.pi / 3, accuracy: 0.0001)
        XCTAssertEqual(drawingState.cursorBodyOffset.dx, 2, accuracy: 0.0001)
        XCTAssertEqual(drawingState.cursorBodyOffset.dy, 4, accuracy: 0.0001)
        XCTAssertEqual(drawingState.fogOffset.dx, -3, accuracy: 0.0001)
        XCTAssertEqual(drawingState.fogOffset.dy, -5, accuracy: 0.0001)
        XCTAssertEqual(drawingState.fogOpacity, 0.2)
        XCTAssertEqual(drawingState.fogScale, 1.1)
        XCTAssertEqual(drawingState.clickProgress, 0.6)
    }

    func testDefaultVisualCursorInitialTipMatchesZeroWindowOrigin() {
        let geometry = CursorWindowGeometry(
            windowSize: CGSize(width: 126, height: 126),
            tipAnchor: CGPoint(x: 60.35, y: 70.3)
        )
        let start = defaultVisualCursorInitialTipPosition(
            windowOrigin: .zero,
            tipAnchor: geometry.tipAnchor
        )

        XCTAssertEqual(geometry.origin(forTipPosition: start), .zero)
        XCTAssertEqual(start.x, geometry.tipAnchor.x, accuracy: 0.0001)
        XCTAssertEqual(start.y, geometry.tipAnchor.y, accuracy: 0.0001)
    }

    func testVisualCursorKeepsPostInteractionIdleStateLongEnoughForFollowupTools() {
        XCTAssertEqual(visualCursorPostInteractionIdleTimeout(), 30)
        XCTAssertGreaterThanOrEqual(visualCursorPostInteractionIdleTimeout(), 30)
    }

    func testCursorPanelReordersWhenForcedEvenIfTargetWindowDidNotChange() {
        let targetWindow = CursorTargetWindow(windowID: 42, layer: 0)

        XCTAssertTrue(
            shouldReorderCursorPanel(
                activeTargetWindow: targetWindow,
                effectiveTargetWindow: targetWindow,
                panelIsVisible: true,
                forceReorder: true
            )
        )
    }

    func testCursorPanelDoesNotReorderWhenVisibleAndTargetWindowIsStable() {
        let targetWindow = CursorTargetWindow(windowID: 42, layer: 0)

        XCTAssertFalse(
            shouldReorderCursorPanel(
                activeTargetWindow: targetWindow,
                effectiveTargetWindow: targetWindow,
                panelIsVisible: true,
                forceReorder: false
            )
        )
    }

    func testVisualCursorRuntimeMapsAppKitUpwardMotionToCursorMotionScreenState() {
        let renderBaseHeading = visualCursorRenderBaseHeading(
            artworkNeutralHeading: SoftwareCursorGlyphMetrics.targetNeutralHeading
        )
        let screenVelocity = visualCursorScreenStateVelocity(
            fromRuntimeVelocity: CGVector(dx: 0, dy: 1),
            yAxisMultiplier: visualCursorRuntimeRenderYAxisMultiplier()
        )
        let renderRotation = normalizedAngle(atan2(screenVelocity.dy, screenVelocity.dx) - renderBaseHeading)
        let appKitForwardHeading = visualCursorAppKitForwardHeading(
            renderRotation: renderRotation,
            artworkNeutralHeading: SoftwareCursorGlyphMetrics.targetNeutralHeading
        )

        XCTAssertEqual(renderBaseHeading, -(3 * CGFloat.pi / 4), accuracy: 0.0001)
        XCTAssertEqual(screenVelocity.dx, 0, accuracy: 0.0001)
        XCTAssertEqual(screenVelocity.dy, -1, accuracy: 0.0001)
        XCTAssertEqual(renderRotation, CGFloat.pi / 4, accuracy: 0.0001)
        XCTAssertEqual(normalizedAngle(appKitForwardHeading), CGFloat.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(
            visualCursorAppKitForwardHeading(
                renderRotation: 0,
                artworkNeutralHeading: SoftwareCursorGlyphMetrics.targetNeutralHeading
            ),
            3 * CGFloat.pi / 4,
            accuracy: 0.0001
        )
    }

    func testCursorMotionPathStartsAndEndsAtExpectedPoints() {
        let path = CursorMotionPath(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120)
        )

        XCTAssertEqual(path.point(at: 0), CGPoint(x: 10, y: 20))
        XCTAssertEqual(path.point(at: 1), CGPoint(x: 210, y: 120))

        let midpoint = path.point(at: 0.5)
        XCTAssertNotEqual(midpoint.x, 110)
        XCTAssertNotEqual(midpoint.y, 70)
    }

    func testCursorMotionPathSupportsStraightVariantForConservativeFallback() {
        let straightPath = CursorMotionPath(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 210, y: 120),
            curveDirection: 0,
            curveScale: 0
        )

        XCTAssertEqual(straightPath.curveScale, 0)
        XCTAssertEqual(straightPath.point(at: 0), CGPoint(x: 10, y: 20))
        XCTAssertEqual(straightPath.point(at: 1), CGPoint(x: 210, y: 120))

        let midpoint = straightPath.point(at: 0.5)
        XCTAssertEqual(midpoint.x, 110, accuracy: 0.001)
        XCTAssertEqual(midpoint.y, 70, accuracy: 0.001)
    }

    func testOfficialCursorMotionModelBuildsTwentyCandidates() {
        let candidates = OfficialCursorMotionModel.makeCandidates(
            start: CGPoint(x: 100, y: 120),
            end: CGPoint(x: 720, y: 380),
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )

        XCTAssertEqual(candidates.count, 20)
    }

    func testOfficialCursorMotionModelChoosesScaledBaseForReferenceSample() {
        let candidates = OfficialCursorMotionModel.makeCandidates(
            start: CGPoint(x: 100, y: 120),
            end: CGPoint(x: 720, y: 380),
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )

        let chosen = OfficialCursorMotionModel.chooseBestCandidate(from: candidates)

        XCTAssertEqual(chosen?.identifier, "a1.05-b1.00-positive")
        XCTAssertEqual(chosen?.kind, .arched)
    }

    func testOfficialCursorMotionGuideProjectionFollowsPathBasisInsteadOfFixedScreenBias() throws {
        let rightUpCandidates = OfficialCursorMotionModel.makeCandidates(
            start: CGPoint(x: 120, y: 620),
            end: CGPoint(x: 960, y: 140),
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )
        let leftUpCandidates = OfficialCursorMotionModel.makeCandidates(
            start: CGPoint(x: 960, y: 620),
            end: CGPoint(x: 120, y: 140),
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )

        let rightUpStartControl = try XCTUnwrap(
            rightUpCandidates.first(where: { $0.identifier == "base-full-guide" })?.path.startControl
        )
        let leftUpStartControl = try XCTUnwrap(
            leftUpCandidates.first(where: { $0.identifier == "base-full-guide" })?.path.startControl
        )

        XCTAssertLessThan(rightUpStartControl.x, 120)
        XCTAssertGreaterThan(leftUpStartControl.x, 960)
    }

    func testOfficialCursorMotionSpringCloseEnoughTimeMatchesRecoveredReference() {
        XCTAssertEqual(OfficialCursorMotionModel.closeEnoughTime, 1.429166666666663, accuracy: 0.000_001)
    }

    func testOfficialCursorMotionTravelDurationUsesRecoveredEndpointLockTiming() {
        let curvedMeasurement = CursorMotionMeasurement(
            length: 1280,
            angleChangeEnergy: 8,
            maxAngleChange: 1.2,
            totalTurn: 4,
            staysInBounds: true
        )

        XCTAssertEqual(
            OfficialCursorMotionModel.calibratedTravelDuration(distance: 140, measurement: curvedMeasurement),
            OfficialCursorMotionModel.closeEnoughTime,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            OfficialCursorMotionModel.calibratedTravelDuration(distance: 900, measurement: curvedMeasurement),
            1.0
        )
    }

    func testHeadingDrivenMotionPrefersNearDirectPathWhenHeadingsAlreadyAlign() throws {
        let start = CGPoint(x: 120, y: 120)
        let end = CGPoint(x: 920, y: 320)
        let direction = normalizedVector(from: start, to: end)

        let candidates = HeadingDrivenCursorMotionModel.makeCandidates(
            start: start,
            end: end,
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800),
            startForward: direction,
            endForward: direction
        )
        let chosen = try XCTUnwrap(HeadingDrivenCursorMotionModel.chooseBestCandidate(from: candidates))
        let directDistance = hypot(end.x - start.x, end.y - start.y)

        XCTAssertEqual(chosen.side, 0)
        XCTAssertLessThan(chosen.measurement.totalTurn, 0.45)
        XCTAssertLessThan(chosen.measurement.length, directDistance * 1.03)
    }

    func testHeadingDrivenMotionPrefersTurnaroundArcWhenStartHeadingOpposesTravel() throws {
        let start = CGPoint(x: 220, y: 520)
        let end = CGPoint(x: 900, y: 280)
        let direction = normalizedVector(from: start, to: end)
        let opposite = CGVector(dx: -direction.dx, dy: -direction.dy)

        let directReference = try XCTUnwrap(
            HeadingDrivenCursorMotionModel.chooseBestCandidate(
                from: HeadingDrivenCursorMotionModel.makeCandidates(
                    start: start,
                    end: end,
                    bounds: CGRect(x: 0, y: 0, width: 1280, height: 800),
                    startForward: direction,
                    endForward: direction
                )
            )
        )
        let turnaround = try XCTUnwrap(
            HeadingDrivenCursorMotionModel.chooseBestCandidate(
                from: HeadingDrivenCursorMotionModel.makeCandidates(
                    start: start,
                    end: end,
                    bounds: CGRect(x: 0, y: 0, width: 1280, height: 800),
                    startForward: opposite,
                    endForward: direction
                )
            )
        )

        XCTAssertNotEqual(turnaround.side, 0)
        XCTAssertGreaterThan(turnaround.measurement.totalTurn, directReference.measurement.totalTurn + 0.8)
        XCTAssertGreaterThan(turnaround.measurement.length, directReference.measurement.length * 1.04)
    }

    func testCursorVisualDynamicsOvershootsAfterTargetStops() {
        let samples = simulateCursorVisualDynamics(
            stopTime: 0.18,
            targetDistance: 320,
            totalTime: 0.75
        )

        let maxX = samples.map(\.tipPosition.x).max() ?? 0
        XCTAssertGreaterThan(maxX, 320.5)
        XCTAssertLessThan(samples[32].fogOffset.dx, -0.25)
    }

    func testCursorVisualDynamicsKeepsAngleInertiaAfterTargetStops() {
        let samples = simulateCursorVisualDynamics(
            stopTime: 0.16,
            targetDistance: 280,
            totalTime: 0.92
        )

        let rotationJustAfterStop = abs(samples[42].rotation)
        let finalRotation = abs(samples.last?.rotation ?? 0)

        XCTAssertGreaterThan(rotationJustAfterStop, 0.03)
        XCTAssertLessThan(finalRotation, 0.02)
    }

    func testCursorVisualDynamicsTracksMovementHeadingInsteadOfOnlyWiggling() {
        let samples = simulateCursorVisualDynamics(
            stopTime: 0.45,
            targetDistance: 360,
            totalTime: 0.50
        )

        let peakRotation = samples.prefix(120).map { abs($0.rotation) }.max() ?? 0

        XCTAssertGreaterThan(peakRotation, 1.5)
    }

    func testVisualCursorIdlePoseKeepsTipAnchoredAndOnlyRotates() {
        let restingTipPosition = CGPoint(x: 184, y: 92)
        let positivePose = visualCursorIdlePose(restingTipPosition: restingTipPosition, phase: .pi / 2)
        let negativePose = visualCursorIdlePose(
            restingTipPosition: restingTipPosition,
            phase: (.pi / 2) + (.pi / CGFloat(0.8))
        )

        XCTAssertEqual(positivePose.tipPosition.x, restingTipPosition.x, accuracy: 0.0001)
        XCTAssertEqual(positivePose.tipPosition.y, restingTipPosition.y, accuracy: 0.0001)
        XCTAssertGreaterThan(positivePose.angleOffset, 0)
        XCTAssertLessThanOrEqual(abs(positivePose.angleOffset), visualCursorIdleRotationAmplitude() + 0.0001)
        XCTAssertGreaterThan(abs(positivePose.angleOffset), 0.08)

        XCTAssertEqual(negativePose.tipPosition.x, restingTipPosition.x, accuracy: 0.0001)
        XCTAssertEqual(negativePose.tipPosition.y, restingTipPosition.y, accuracy: 0.0001)
        XCTAssertLessThan(negativePose.angleOffset, 0)
        XCTAssertLessThanOrEqual(abs(negativePose.angleOffset), visualCursorIdleRotationAmplitude() + 0.0001)
        XCTAssertGreaterThan(abs(negativePose.angleOffset), 0.08)
    }

    private func makeSnapshot(treeLines: [String], focusedSummary: String?, selectedText: String? = nil) -> AppSnapshot {
        AppSnapshot(
            app: RunningAppDescriptor(
                name: "Sample Chat",
                bundleIdentifier: "com.example.SampleChat",
                pid: 18_465,
                runningApplication: NSRunningApplication.current
            ),
            windowTitle: "Sample Chat",
            windowBounds: nil,
            targetWindowID: nil,
            targetWindowLayer: nil,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: treeLines,
            focusedSummary: focusedSummary,
            focusedElement: nil,
            selectedText: selectedText,
            windowElement: nil,
            elements: [:]
        )
    }

    private func simulateCursorVisualDynamics(
        stopTime: CGFloat,
        targetDistance: CGFloat,
        totalTime: CGFloat,
        stepCount: Int = 240
    ) -> [CursorVisualRenderState] {
        var state = CursorVisualDynamicsAnimator.state(at: CGPoint(x: 0, y: 0))
        var samples: [CursorVisualRenderState] = []

        for step in 1...stepCount {
            let time = totalTime * (CGFloat(step) / CGFloat(stepCount))
            let targetX: CGFloat
            if time < stopTime {
                targetX = targetDistance * (time / stopTime)
            } else {
                targetX = targetDistance
            }

            let result = CursorVisualDynamicsAnimator.advance(
                state: state,
                targetTipPosition: CGPoint(x: targetX, y: 0),
                targetTime: time,
                baseHeading: -(3 * .pi / 4)
            )
            state = result.state
            samples.append(result.renderState)
        }

        return samples
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi {
            value -= 2 * .pi
        }
        while value < -.pi {
            value += 2 * .pi
        }
        return value
    }

    private func normalizedVector(from start: CGPoint, to end: CGPoint) -> CGVector {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        return CGVector(dx: dx / length, dy: dy / length)
    }

    private func makeNoisyTestImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 37 + y * 17) & 0xFF)
                pixels[offset + 1] = UInt8((x * 11 + y * 43) & 0xFF)
                pixels[offset + 2] = UInt8((x * 71 + y * 5) & 0xFF)
                pixels[offset + 3] = 255
            }
        }

        return try makeTestImage(width: width, height: height, pixels: pixels)
    }

    private func makeSolidTestImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 80
            pixels[index + 1] = 140
            pixels[index + 2] = 220
            pixels[index + 3] = 255
        }

        return try makeTestImage(width: width, height: height, pixels: pixels)
    }

    private func makeTestImage(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )

        return try XCTUnwrap(image)
    }

    private func imageSize(in data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }
}
