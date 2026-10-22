import AppKit
import CoreGraphics
import Foundation
import OpenComputerUseKit

struct MCPResponse {
    let id: Int?
    let result: [String: Any]?
    let error: [String: Any]?
}

final class MCPClient {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var nextID = 1

    init(executableURL: URL, arguments: [String], environment: [String: String]? = nil) throws {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        stdin = stdinPipe.fileHandleForWriting
        stdout = stdoutPipe.fileHandleForReading
    }

    func initialize() throws {
        _ = try request(method: "initialize", params: [
            "clientInfo": [
                "name": "OpenComputerUseSmokeSuite",
                "version": "1.1.2",
            ],
            "capabilities": [:],
            "protocolVersion": "2025-03-26",
        ])

        try notify(method: "notifications/initialized", params: [:])
    }

    func listTools() throws -> [[String: Any]] {
        let response = try request(method: "tools/list", params: [:])
        return response.result?["tools"] as? [[String: Any]] ?? []
    }

    func callTool(_ name: String, arguments: [String: Any]) throws -> String {
        let response = try request(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])

        if let error = response.error {
            throw SmokeError.message("JSON-RPC error: \(error)")
        }

        let result = response.result ?? [:]
        if (result["isError"] as? Bool) == true {
            let text = extractText(from: result) ?? "unknown tool error"
            throw SmokeError.message(text)
        }

        guard let text = extractText(from: result) else {
            throw SmokeError.message("Tool \(name) returned no text content.")
        }

        return text
    }

    func terminate() {
        process.terminate()
    }

    private func notify(method: String, params: [String: Any]) throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        try write(payload)
    }

    private func request(method: String, params: [String: Any]) throws -> MCPResponse {
        let id = nextID
        nextID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        try write(payload)
        return try readResponse(expectedID: id)
    }

    private func write(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        stdin.write(data)
        stdin.write(Data([0x0A]))
    }

    private func readResponse(expectedID: Int) throws -> MCPResponse {
        let deadline = Date().addingTimeInterval(20)
        var buffer = Data()

        while Date() < deadline {
            let chunk = try stdout.read(upToCount: 1) ?? Data()
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            buffer.append(chunk)

            if chunk == Data([0x0A]) {
                let lineData = buffer.dropLast()
                buffer.removeAll(keepingCapacity: true)
                guard !lineData.isEmpty else {
                    continue
                }

                let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] ?? [:]
                let id = object["id"] as? Int

                if id != expectedID {
                    continue
                }

                return MCPResponse(
                    id: id,
                    result: object["result"] as? [String: Any],
                    error: object["error"] as? [String: Any]
                )
            }
        }

        throw SmokeError.message("Timed out waiting for JSON-RPC response \(expectedID)")
    }

    private func extractText(from result: [String: Any]) -> String? {
        let content = result["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }
}

enum SmokeError: Error {
    case message(String)
}

@main
enum OpenComputerUseSmokeSuite {
    static func main() throws {
        let productsDirectory = try locateProductsDirectory()
        let fixtureURL = productsDirectory.appendingPathComponent("OpenComputerUseFixture")
        let serverURL = productsDirectory.appendingPathComponent("OpenComputerUse")
        let appName = "OpenComputerUseFixture"
        let mode = SmokeMode(arguments: CommandLine.arguments)

        terminateExistingFixtures(named: appName)
        try? FileManager.default.removeItem(at: FixtureBridge.stateFileURL)

        let fixture = Process()
        fixture.executableURL = fixtureURL
        fixture.environment = smokeFixtureEnvironment()
        fixture.standardOutput = Pipe()
        fixture.standardError = Pipe()
        try fixture.run()

        defer {
            fixture.terminate()
        }

        Thread.sleep(forTimeInterval: 1.5)

        switch mode {
        case .full:
            try runFullSmoke(serverURL: serverURL, appName: appName)
        case .cursorIdleOnly:
            try runCursorIdleSmoke(serverURL: serverURL, appName: appName)
        }
    }

    private static func runFullSmoke(serverURL: URL, appName: String) throws {
        let client = try MCPClient(executableURL: serverURL, arguments: ["mcp"], environment: smokeServerEnvironment())
        defer {
            client.terminate()
        }

        try client.initialize()

        let tools = try client.listTools()
        let expectedTools: Set<String> = [
            "list_apps", "get_app_state", "query", "click", "perform_secondary_action",
            "scroll", "drag", "type_text", "press_key", "set_value", "select_text",
            "read_clipboard", "write_clipboard",
        ]
        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        guard tools.count == expectedTools.count, toolNames == expectedTools else {
            throw SmokeError.message("Expected tools \(expectedTools.sorted()), got \(toolNames.sorted())")
        }

        print("1. list_apps")
        let apps = try client.callTool("list_apps", arguments: [:])
        try expect(apps.contains(appName), "Fixture app should appear in list_apps output.")

        print("2. get_app_state")
        var state = try client.callTool("get_app_state", arguments: [
            "app": appName,
        ])
        var index = parseElementIndex(state)
        try expect(index.keys.contains("fixture-increment"), "fixture button should be indexed")
        let initialCounter = parseCounterValue(state)

        print("3. click element_index")
        state = try client.callTool("click", arguments: [
            "app": appName,
            "element_index": index["fixture-increment"]!.index,
        ])
        try expect(parseCounterValue(state) == initialCounter + 1, "click should increment the counter")

        print("4. click coordinate")
        index = parseElementIndex(state)
        let buttonFrame = index["fixture-increment"]!.frame
        state = try client.callTool("click", arguments: [
            "app": appName,
            "x": buttonFrame.midX,
            "y": buttonFrame.midY,
        ])
        try expect(parseCounterValue(state) == initialCounter + 2, "coordinate click should increment the counter again")

        print("5. perform_secondary_action")
        let windowIndex = index["fixture-window"]?.index ?? "0"
        _ = try client.callTool("perform_secondary_action", arguments: [
            "app": appName,
            "element_index": windowIndex,
            "action": "Raise",
        ])

        print("6. set_value")
        state = try client.callTool("set_value", arguments: [
            "app": appName,
            "element_index": index["fixture-input"]!.index,
            "value": "set-value-ok",
        ])
        try expect(state.contains("set-value-ok"), "set_value should update the text field")

        print("7. type_text")
        let inputFrame = index["fixture-input"]!.frame
        _ = try client.callTool("click", arguments: [
            "app": appName,
            "x": inputFrame.midX,
            "y": inputFrame.midY,
        ])
        state = try client.callTool("type_text", arguments: [
            "app": appName,
            "text": "-typed",
        ])
        try expect(state.contains("set-value-ok-typed"), "type_text should append literal text to the focused text field")

        print("8. select_text")
        index = parseElementIndex(state)
        state = try client.callTool("select_text", arguments: [
            "app": appName,
            "element_index": index["fixture-input"]!.index,
            "text": "value-ok",
        ])
        try expect(state.contains("Selected text: [value-ok]"), "select_text should select the requested text inside the text field")

        print("9. press_key")
        index = parseElementIndex(state)
        let keyCaptureFrame = index["fixture-key-capture"]!.frame
        _ = try client.callTool("click", arguments: [
            "app": appName,
            "x": keyCaptureFrame.midX,
            "y": keyCaptureFrame.midY,
        ])
        state = try client.callTool("press_key", arguments: [
            "app": appName,
            "key": "Return",
        ])
        try expect(state.contains("Last key: Return"), "press_key should update the key capture view")

        print("10. scroll")
        index = parseElementIndex(state)
        let scrollIndex = index["fixture-scroll-view"]!.index
        state = try client.callTool("scroll", arguments: [
            "app": appName,
            "direction": "down",
            "element_index": scrollIndex,
            "pages": 1,
        ])
        try expect(!state.contains("Scroll offset: 0"), "scroll should move the scroll view")

        print("11. drag")
        index = parseElementIndex(state)
        let dragFrame = index["fixture-drag-pad"]!.frame
        state = try client.callTool("drag", arguments: [
            "app": appName,
            "from_x": dragFrame.minX + 30,
            "from_y": dragFrame.minY + 30,
            "to_x": dragFrame.maxX - 30,
            "to_y": dragFrame.maxY - 30,
        ])
        try expect(state.contains("Last drag:"), "drag should update the drag status label")
        try expect(!state.contains("Last drag: none"), "drag should report a captured path")

        print("Smoke suite completed.")
    }

    private static func runCursorIdleSmoke(serverURL: URL, appName: String) throws {
        print("1. cursor idle observation setup")
        let observationURL = cursorObservationFileURL()
        try? FileManager.default.removeItem(at: observationURL)
        var environment = smokeServerEnvironment()
        environment["OPEN_COMPUTER_USE_VISUAL_CURSOR"] = "1"
        environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE"] = observationURL.path

        let client = try MCPClient(executableURL: serverURL, arguments: ["mcp"], environment: environment)
        defer {
            client.terminate()
        }

        try client.initialize()
        _ = try client.callTool("get_app_state", arguments: [
            "app": appName,
        ])

        print("2. trigger click and wait for idle overlay")
        let state = try client.callTool("click", arguments: [
            "app": appName,
            "element_index": "1",
        ])
        try expect(state.contains("Counter:"), "cursor smoke click should still return fixture state")

        let firstIdleSnapshot = try waitForCursorObservation(at: observationURL, phase: "idle")
        Thread.sleep(forTimeInterval: 0.25)
        let secondIdleSnapshot = try waitForCursorObservation(at: observationURL, phase: "idle")

        print("3. assert anchored tip plus changing rotation")
        let firstTip = try expectPoint(firstIdleSnapshot.tipPosition, name: "first tip position")
        let secondTip = try expectPoint(secondIdleSnapshot.tipPosition, name: "second tip position")
        let firstResting = try expectPoint(firstIdleSnapshot.restingTipPosition, name: "first resting tip position")
        let secondResting = try expectPoint(secondIdleSnapshot.restingTipPosition, name: "second resting tip position")
        let firstRotation = try expectValue(firstIdleSnapshot.rotation, name: "first rotation")
        let secondRotation = try expectValue(secondIdleSnapshot.rotation, name: "second rotation")

        try expect(abs(firstTip.x - secondTip.x) < 0.25, "idle cursor should stay anchored horizontally instead of shaking")
        try expect(abs(firstTip.y - secondTip.y) < 0.25, "idle cursor should stay anchored vertically")
        try expect(distanceBetween(firstTip, firstResting) < 0.35, "idle cursor tip should stay near resting position")
        try expect(distanceBetween(secondTip, secondResting) < 0.35, "idle cursor tip should keep resting anchor")
        try expect(abs(secondRotation - firstRotation) > 0.01, "idle cursor should keep a clearly visible tiny rotation wobble")

        print("Cursor idle smoke completed.")
    }

    private static func smokeServerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY"] = "1"
        return environment
    }

    private static func smokeFixtureEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["OPEN_COMPUTER_USE_FIXTURE_HEADLESS"] = "1"
        return environment
    }

    private static func locateProductsDirectory() throws -> URL {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return executableURL.deletingLastPathComponent()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw SmokeError.message(message)
        }
    }

    private static func terminateExistingFixtures(named name: String) {
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            if app.localizedName == name {
                return true
            }

            return app.executableURL?.deletingPathExtension().lastPathComponent == name
        }

        for app in candidates {
            _ = app.terminate()
        }

        for app in candidates where !app.isTerminated {
            _ = app.forceTerminate()
        }

        if !candidates.isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private static func parseElementIndex(_ state: String) -> [String: (index: String, frame: CGRect)] {
        var result: [String: (String, CGRect)] = [:]

        for rawLine in state.split(separator: "\n") {
            let line = String(rawLine)
            guard
                let identifierRange = line.range(of: " ID: "),
                let frameRange = line.range(of: " Frame: ")
            else {
                continue
            }

            let prefix = line[..<identifierRange.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let index = prefix.split(separator: " ").first.map(String.init) else {
                continue
            }

            let identifierSlice = line[identifierRange.upperBound..<frameRange.lowerBound]
            let identifier = identifierSlice
                .components(separatedBy: " Value:")
                .first?
                .components(separatedBy: " Secondary Actions:")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let frame = parseFrame(String(line[frameRange.upperBound...]))
            result[identifier] = (index, frame)
        }

        return result
    }

    private static func parseFrame(_ text: String) -> CGRect {
        let values = text
            .components(separatedBy: ",")
            .compactMap { part -> Double? in
                part.split(separator: "=").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            }

        guard values.count == 4 else {
            return .zero
        }

        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func parseCounterValue(_ state: String) -> Int {
        guard
            let range = state.range(of: "Counter: "),
            let value = state[range.upperBound...].split(whereSeparator: { !$0.isNumber }).first,
            let counter = Int(value)
        else {
            return -1
        }

        return counter
    }

    private static func cursorObservationFileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-computer-use-smoke", isDirectory: true)
            .appendingPathComponent("visual-cursor-observation.json")
    }

    private static func waitForCursorObservation(at url: URL, phase: String, timeout: TimeInterval = 6) throws -> VisualCursorObservationSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot: VisualCursorObservationSnapshot?

        while Date() < deadline {
            if
                let data = try? Data(contentsOf: url),
                let snapshot = try? JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: data)
            {
                lastSnapshot = snapshot
                if snapshot.phase == phase {
                    return snapshot
                }
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        throw SmokeError.message("Timed out waiting for cursor observation phase \(phase). Last snapshot: \(String(describing: lastSnapshot))")
    }

    private static func expectPoint(_ point: VisualCursorObservationPoint?, name: String) throws -> CGPoint {
        guard let point else {
            throw SmokeError.message("Missing \(name)")
        }

        return CGPoint(x: point.x, y: point.y)
    }

    private static func expectValue(_ value: Double?, name: String) throws -> Double {
        guard let value else {
            throw SmokeError.message("Missing \(name)")
        }

        return value
    }

    private static func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private enum SmokeMode {
    case full
    case cursorIdleOnly

    init(arguments: [String]) {
        if arguments.contains("--cursor-idle-only") {
            self = .cursorIdleOnly
        } else {
            self = .full
        }
    }
}
