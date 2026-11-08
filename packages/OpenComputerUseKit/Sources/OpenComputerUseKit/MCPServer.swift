import Foundation

let computerUseServerInstructions = """
Computer Use tools let you interact with macOS apps by performing UI actions.

Some apps might have a separate dedicated plugin or skill. You may want to use that plugin or skill instead of Computer Use when it seems like a good fit for the task. While the separate plugin or skill may not expose every feature in the app, if the plugin can perform the task with its available features, prefer it. If the needed capability is not exposed there, use Computer Use may be appropriate for the missing interaction.

Begin by calling `get_app_state` every turn you want to use Computer Use to get the latest state before acting. Codex will automatically stop the session after each assistant turn, so this step is required before interacting with apps in a new assistant turn.

The available tools are list_apps, get_app_state, click, perform_secondary_action, scroll, drag, type_text, press_key, set_value, select_text, and query. If any of these are not available in your environment, use tool_search to surface one before calling any Computer Use action tools.

Computer Use tools allow you to use the user's apps in the background, so while you're using an app, the user can continue to use other apps on their computer. Avoid doing anything that would disrupt the user's active session, such as overwriting the contents of their clipboard, unless they asked you to!

After each action, use the action result or fetch the latest state to verify the UI changed as expected.
Prefer element-targeted interactions over coordinate clicks when an index for the targeted element is available. Note that element indices are the sequential integers from the app state's accessibility tree.
Avoid falling back to AppleScript during a computer use session. Prefer Computer Use tools as much as possible to complete tasks.
Ask the user before taking destructive or externally visible actions such as sending, deleting, or purchasing. If helpful, you can ask follow-up questions before taking action to make sure you’re understanding the user’s request correctly.
"""

public final class StdioMCPServer {
    private let service: ComputerUseService
    private let dispatcher: ComputerUseToolDispatcher
    private let backgroundStateReset: () -> Void

    public init(
        service: ComputerUseService = ComputerUseService(),
        backgroundStateReset: @escaping () -> Void = resetOpenComputerUseBackgroundWindowState
    ) {
        self.service = service
        self.dispatcher = ComputerUseToolDispatcher(service: service)
        self.backgroundStateReset = backgroundStateReset
    }

    public func run() throws {
        defer { endSession() }
        let requests = MCPStdinRequests()
        while let request = requests.next() {
            // This thread's autorelease pool never drains on its own: each response's encoded
            // bytes (a screenshot's base64 among them) stayed alive for the whole session.
            autoreleasepool {
                let response = handle(line: request.line)
                if requests.finish(), let response {
                    FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
                }
            }
        }
    }

    public func handle(line: String) -> String? {
        do {
            guard let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return try encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }

            let method = payload["method"] as? String
            // A message without an id is a notification, which JSON-RPC never answers.
            guard let id = payload["id"] else {
                if method == "notifications/turn-ended" {
                    endSession()
                }
                return nil
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "protocolVersion": "2025-03-26",
                        "serverInfo": [
                            "name": "open-computer-use",
                            "version": openComputerUseVersion,
                        ],
                        "capabilities": [
                            "tools": [
                                "listChanged": false,
                            ],
                        ],
                        "instructions": computerUseServerInstructions,
                    ]
                )
            case "ping":
                return try encodeJSONRPCResult(id: id, result: [:])
            case "tools/list":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "tools": ToolDefinitions.all.map(\.asDictionary),
                    ]
                )
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = try dispatcher.callTool(name: name, arguments: arguments)
                return try encodeJSONRPCResult(
                    id: id,
                    result: result.asDictionary
                )
            default:
                if method == nil {
                    return nil
                }

                return try encodeJSONRPCError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
            }
        } catch let error as ComputerUseError {
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            let result = ToolCallResult.text(error.errorDescription ?? String(describing: error), isError: error.toolResultIsError)
            return try? encodeJSONRPCResult(id: id, result: result.asDictionary)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            return try? encodeJSONRPCResult(
                id: id,
                result: [
                    "content": [
                        [
                            "type": "text",
                            "text": message,
                        ],
                    ],
                    "isError": true,
                ]
            )
        }
    }

    /// Release state that is scoped to one MCP client session. App-hosted MCP
    /// connections call this explicitly because they use `handle(line:)`
    /// instead of the stdio `run()` loop.
    public func endSession() {
        service.clearQueryIndexes()
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.reset()
        }
        backgroundStateReset()
    }

    private func encodeJSONRPCResult(id: Any?, result: [String: Any]) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
    }

    private func encodeJSONRPCError(id: Any?, code: Int, message: String) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }

        return text
    }
}

/// The requests of a stdio MCP session. Lines are read on their own thread, so a `notifications/cancelled` is seen while
/// a request runs; the caller still handles requests one at a time, in order. A cancelled request that hasn't started
/// never runs. One that is running finishes (an action can't be stopped halfway), but its answer is dropped, as MCP
/// asks of a server.
public final class MCPStdinRequests: @unchecked Sendable {
    public struct Request {
        public let line: String
        let key: String?
    }

    private let condition = NSCondition()
    private var waiting: [Request] = []
    private var running: String?
    private var runningCancelled = false
    private var ended = false

    public init(readLine: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) }) {
        Thread { [self] in
            while let line = readLine() {
                // No run loop drains this thread's autorelease pool either.
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { autoreleasepool { add(line) } }
            }
            condition.lock()
            ended = true
            condition.broadcast()
            condition.unlock()
        }.start()
    }

    /// The next request in order, waiting for one; nil once the input has ended and every request was handled.
    public func next() -> Request? {
        condition.lock()
        defer { condition.unlock() }
        while waiting.isEmpty && !ended { condition.wait() }
        guard !waiting.isEmpty else { return nil }
        let request = waiting.removeFirst()
        running = request.key
        runningCancelled = false
        return request
    }

    /// Ends the request from `next`; false when it was cancelled while it ran, so its answer is dropped.
    public func finish() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        running = nil
        return !runningCancelled
    }

    private func add(_ line: String) {
        let payload = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        condition.lock()
        defer { condition.unlock() }
        if payload?["method"] as? String == "notifications/cancelled" {
            let key = Self.key((payload?["params"] as? [String: Any])?["requestId"])
            if let key, let index = waiting.firstIndex(where: { $0.key == key }) {
                waiting.remove(at: index)
            } else if let key, key == running {
                runningCancelled = true
            }
            return
        }
        waiting.append(Request(line: line, key: Self.key(payload?["id"])))
        condition.signal()
    }

    /// A JSON-RPC id as a key: 7 and "7" are different ids.
    private static func key(_ id: Any?) -> String? {
        switch id {
        case let text as String: "s:" + text
        case let number as NSNumber: "n:" + number.stringValue
        default: nil
        }
    }
}
