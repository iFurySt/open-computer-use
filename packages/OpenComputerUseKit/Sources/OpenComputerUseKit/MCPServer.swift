import Foundation

let computerUseServerInstructions = """
Computer Use tools let you interact with macOS apps by performing UI actions.

Some apps might have a separate dedicated plugin or skill. You may want to use that plugin or skill instead of Computer Use when it seems like a good fit for the task. While the separate plugin or skill may not expose every feature in the app, if the plugin can perform the task with its available features, prefer it. If the needed capability is not exposed there, use Computer Use may be appropriate for the missing interaction.

Begin by calling `get_app_state` every turn you want to use Computer Use to get the latest state before acting. Codex will automatically stop the session after each assistant turn, so this step is required before interacting with apps in a new assistant turn.

The available tools are list_apps, get_app_state, click, perform_secondary_action, scroll, drag, type_text, press_key, set_value, select_text, query, read_clipboard, and write_clipboard. If any of these are not available in your environment, use tool_search to surface one before calling any Computer Use action tools.

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
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            if let response = handle(line: line) {
                FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
            }
        }
    }

    public func handle(line: String) -> String? {
        do {
            guard let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return try encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }

            let method = payload["method"] as? String
            let id = payload["id"]
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
            case "notifications/initialized":
                return nil
            case "notifications/turn-ended":
                endSession()
                return nil
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
