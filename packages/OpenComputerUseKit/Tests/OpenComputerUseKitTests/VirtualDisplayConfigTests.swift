import ApplicationServices
import Darwin
import XCTest
@testable import OpenComputerUseKit

final class VirtualDisplayConfigTests: XCTestCase {
    func testDefaultsAndStrictBooleanPrecedence() {
        let enabled: [String: Any] = ["virtualDisplay": ["enabled": true]]
        XCTAssertFalse(VirtualDisplayConfig.resolve(document: [:], environment: [:]).enabled)
        XCTAssertTrue(VirtualDisplayConfig.resolve(document: enabled, environment: [:]).enabled)
        XCTAssertFalse(VirtualDisplayConfig.resolve(document: enabled, environment: [VirtualDisplayConfig.environmentKey: "false"]).enabled)
        XCTAssertTrue(VirtualDisplayConfig.resolve(document: [:], environment: [VirtualDisplayConfig.environmentKey: "true"]).enabled)
        for value in ["1", "yes", "", "TRUE"] {
            XCTAssertFalse(VirtualDisplayConfig.resolve(document: enabled, environment: [VirtualDisplayConfig.environmentKey: value]).enabled)
        }
        for value in [1, "true", NSNull(), [], [:]] as [Any] {
            XCTAssertFalse(VirtualDisplayConfig.resolve(document: ["virtualDisplay": ["enabled": value]], environment: [:]).enabled)
        }
        XCTAssertFalse(VirtualDisplayConfig.resolve(document: ["virtualDisplay": false], environment: [:]).enabled)
    }

    func testReloadedConfigControlsSchemaAndRejectsCreationBeforeAppLookup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let keys = OCUConfiguration.environmentKeys
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, getenv($0).map { String(cString: $0) }) })
        for key in keys { unsetenv(key) }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv("OPEN_COMPUTER_USE_CONFIG_FILE", file.path, 1)
        func placement() -> [String: Any]? {
            let schema = ToolDefinitions.all.first { $0.name == "get_app_state" }?.inputSchema
            return (schema?["properties"] as? [String: Any])?["window_placement"] as? [String: Any]
        }
        XCTAssertNil(placement())
        let dispatcher = ComputerUseToolDispatcher()
        XCTAssertThrowsError(try dispatcher.callTool(name: "get_app_state", arguments: ["app": "does-not-exist", "window_placement": "agent_display"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("disabled by virtualDisplay.enabled"))
        }
        // Exercise the lower-level entry without creating a display or touching a real window.
        XCTAssertThrowsError(try AgentDisplay.shared.park(windowID: 0, pid: getpid(), window: AXUIElementCreateApplication(getpid()))) { error in
            XCTAssertTrue(error.localizedDescription.contains("disabled by virtualDisplay.enabled"))
        }
        XCTAssertEqual(AgentDisplay.shared.displayID, 0)
        try Data(#"{"virtualDisplay":{"enabled":true}}"#.utf8).write(to: file, options: .atomic)
        XCTAssertTrue(VirtualDisplayConfig.current.enabled)
        XCTAssertEqual(placement()?["enum"] as? [String], ["keep", "agent_display", "restore"])
        setenv(VirtualDisplayConfig.environmentKey, "false", 1)
        XCTAssertNil(placement())
        unsetenv(VirtualDisplayConfig.environmentKey)
        try Data(#"{"virtualDisplay":{"enabled":false}}"#.utf8).write(to: file, options: .atomic)
        XCTAssertNil(placement())
        try Data("broken".utf8).write(to: file, options: .atomic)
        XCTAssertFalse(VirtualDisplayConfig.current.enabled)
        XCTAssertTrue(keys.contains(VirtualDisplayConfig.environmentKey), "app-agent requests must clear missing overrides")
    }
}
