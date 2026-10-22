import CoreGraphics
import Foundation

func normalizedElementIndexArgument(_ value: Any?) -> String? {
    if let string = value as? String {
        return string.isEmpty ? nil : string
    }

    if let integer = value as? Int {
        return String(integer)
    }

    if let number = value as? NSNumber {
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return nil
        }

        return normalizedElementIndexNumber(number.doubleValue)
    }

    if let double = value as? Double {
        return normalizedElementIndexNumber(double)
    }

    return nil
}

private func normalizedElementIndexNumber(_ value: Double) -> String? {
    guard value.isFinite, value.rounded(.towardZero) == value else {
        return nil
    }

    guard value >= Double(Int.min), value <= Double(Int.max) else {
        return nil
    }

    return String(Int(value))
}

public final class ComputerUseToolDispatcher {
    private let service: ComputerUseService

    public init(service: ComputerUseService = ComputerUseService()) {
        self.service = service
    }

    public func callTool(name: String, arguments: [String: Any]) throws -> ToolCallResult {
        switch name {
        case "list_apps":
            return service.listApps()
        case "query":
            let matches = try service.query(
                app: requireString("app", in: arguments),
                text: try validatedQueryString(arguments["text"], key: "text"),
                role: try validatedQueryString(arguments["role"], key: "role"),
                exact: try validatedQueryExact(arguments["exact"]),
                limit: try optionalPositiveInt("limit", in: arguments) ?? 20,
                maxNodes: try optionalPositiveInt("max_nodes", in: arguments) ?? 500,
                windowID: try validatedQueryWindowID(arguments["window_id"])
            )
            return .text(try renderedQueryMatches(matches))
        case "get_app_state":
            return try service.getAppState(
                app: requireString("app", in: arguments),
                textLimit: try optionalTextLimit("text_limit", in: arguments) ?? .defaults,
                treeLimits: AccessibilityTreeLimits.defaults.replacing(
                    maxNodeCount: try optionalPositiveInt("max_tree_nodes", in: arguments),
                    maxDepth: try optionalPositiveInt("max_tree_depth", in: arguments)
                ),
                windowPlacement: try parseWindowPlacement(optionalString("window_placement", in: arguments)),
                observation: SnapshotObservationOptions(
                    includeAX: try strictObservationBool("include_ax", in: arguments),
                    includeScreenshot: try strictObservationBool("include_screenshot", in: arguments),
                    marks: try strictObservationBool("marks", in: arguments, default: false),
                    zoom: try optionalZoom(in: arguments)
                )
            )
        case "click":
            return try service.click(
                app: requireString("app", in: arguments),
                elementIndex: optionalElementIndex(in: arguments),
                x: optionalDouble("x", in: arguments),
                y: optionalDouble("y", in: arguments),
                clickCount: Int(optionalDouble("click_count", in: arguments) ?? 1),
                mouseButton: optionalString("mouse_button", in: arguments) ?? "left",
                clickMethod: try parseClickMethod(optionalString("click_method", in: arguments))
            )
        case "perform_secondary_action":
            return try service.performSecondaryAction(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                action: requireString("action", in: arguments)
            )
        case "scroll":
            return try service.scroll(
                app: requireString("app", in: arguments),
                direction: requireString("direction", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                pages: optionalDouble("pages", in: arguments) ?? 1
            )
        case "drag":
            return try service.drag(
                app: requireString("app", in: arguments),
                fromX: requireDouble("from_x", in: arguments),
                fromY: requireDouble("from_y", in: arguments),
                toX: requireDouble("to_x", in: arguments),
                toY: requireDouble("to_y", in: arguments)
            )
        case "type_text":
            return try service.typeText(
                app: requireString("app", in: arguments),
                text: requireString("text", in: arguments),
                keyMethod: try parseKeyMethod(optionalString("key_method", in: arguments))
            )
        case "press_key":
            return try service.pressKey(
                app: requireString("app", in: arguments),
                key: requireString("key", in: arguments),
                keyMethod: try parseKeyMethod(optionalString("key_method", in: arguments))
            )
        case "set_value":
            return try service.setValue(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                value: requireString("value", in: arguments)
            )
        case "select_text":
            return try service.selectText(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                text: requireString("text", in: arguments),
                prefix: try selectionString("prefix", in: arguments),
                suffix: try selectionString("suffix", in: arguments),
                selection: try parseSelectionMode(try selectionString("selection", in: arguments))
            )
        default:
            throw ComputerUseError.unsupportedTool(name)
        }
    }

    public func callToolAsResult(name: String, arguments: [String: Any]) -> ToolCallResult {
        do {
            return try callTool(name: name, arguments: arguments)
        } catch let error as ComputerUseError {
            return ToolCallResult.text(
                error.errorDescription ?? String(describing: error),
                isError: error.toolResultIsError
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return ToolCallResult.text(message, isError: true)
        }
    }

    private func requireString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func strictObservationBool(_ key: String, in arguments: [String: Any], default fallback: Bool = true) throws -> Bool {
        guard let value = arguments[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ComputerUseError.invalidArguments("\(key) must be a boolean")
        }
        return number.boolValue
    }

    /// `zoom` as {x, y, width, height}; the range is checked with the other observation options.
    private func optionalZoom(in arguments: [String: Any]) throws -> CGRect? {
        guard let value = arguments["zoom"] else { return nil }
        let box = value as? [String: Any]
        func fraction(_ key: String) throws -> CGFloat {
            guard let number = box?[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ComputerUseError.invalidArguments("zoom must be an object with numeric x, y, width and height")
            }
            return CGFloat(number.doubleValue)
        }
        return CGRect(x: try fraction("x"), y: try fraction("y"), width: try fraction("width"), height: try fraction("height"))
    }

    private func optionalBool(_ key: String, in arguments: [String: Any]) -> Bool? {
        switch arguments[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return Bool(value.lowercased())
        default: return nil
        }
    }

    /// Machine-readable matches with explicit completeness metadata.
    private func renderedQueryMatches(_ matches: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: matches, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.stateUnavailable("Query response could not be encoded")
        }
        return text
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        arguments[key] as? String
    }

    private func selectionString(_ key: String, in arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else {
            throw ComputerUseError.invalidArguments("\(key) must be a string")
        }
        return string
    }

    private func parseSelectionMode(_ raw: String?) throws -> TextSelectionMode {
        guard let raw else { return .text }

        guard let mode = TextSelectionMode(rawValue: raw) else {
            throw ComputerUseError.message(
                "selection must be one of \(TextSelectionMode.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        return mode
    }

    private func optionalTextLimit(_ key: String, in arguments: [String: Any]) throws -> SnapshotTextLimit? {
        guard let value = arguments[key] else {
            return nil
        }

        if let string = value as? String {
            guard string.lowercased() == SnapshotTextLimit.maxKeyword else {
                throw ComputerUseError.invalidArguments("\(key) must be a positive integer or max")
            }
            return .max
        }

        let maxCount = try positiveInt(from: value, key: key, expectedDescription: "a positive integer or max")
        return SnapshotTextLimit(maxCount: maxCount)
    }

    private func requireElementIndex(in arguments: [String: Any]) throws -> String {
        guard let value = optionalElementIndex(in: arguments) else {
            throw ComputerUseError.missingArgument("element_index")
        }

        return value
    }

    private func optionalElementIndex(in arguments: [String: Any]) -> String? {
        normalizedElementIndexArgument(arguments["element_index"])
    }

    private func requireDouble(_ key: String, in arguments: [String: Any]) throws -> Double {
        guard let value = optionalDouble(key, in: arguments) else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func optionalDouble(_ key: String, in arguments: [String: Any]) -> Double? {
        if let double = arguments[key] as? Double {
            return double
        }

        if let integer = arguments[key] as? Int {
            return Double(integer)
        }

        if let number = arguments[key] as? NSNumber {
            return number.doubleValue
        }

        return nil
    }

    private func optionalPositiveInt(_ key: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key] else {
            return nil
        }

        return try positiveInt(from: value, key: key, expectedDescription: "a positive integer")
    }

    private func positiveInt(from value: Any, key: String, expectedDescription: String) throws -> Int {
        if let integer = value as? Int {
            return try validatePositiveInt(integer, key: key, expectedDescription: expectedDescription)
        }

        if let double = value as? Double {
            return try validatePositiveWholeNumber(double, key: key, expectedDescription: expectedDescription)
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
            }
            return try validatePositiveWholeNumber(number.doubleValue, key: key, expectedDescription: expectedDescription)
        }

        throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
    }

    private func validatePositiveWholeNumber(_ value: Double, key: String, expectedDescription: String) throws -> Int {
        guard value.isFinite, value.rounded(.towardZero) == value else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }

        guard value >= Double(Int.min), value <= Double(Int.max) else {
            throw ComputerUseError.invalidArguments("\(key) is outside the supported integer range")
        }

        return try validatePositiveInt(Int(value), key: key, expectedDescription: expectedDescription)
    }

    private func validatePositiveInt(_ value: Int, key: String, expectedDescription: String) throws -> Int {
        guard value > 0 else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }
        return value
    }
}

public struct OpenComputerUseCallSpec {
    public let tool: String
    public let arguments: [String: Any]

    public init(tool: String, arguments: [String: Any]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct OpenComputerUseCallOutput {
    public let jsonObject: Any
    public let hasToolError: Bool

    public init(jsonObject: Any, hasToolError: Bool) {
        self.jsonObject = jsonObject
        self.hasToolError = hasToolError
    }

    public func jsonText() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode call output as JSON.")
        }
        return text
    }
}

public typealias OpenComputerUseSleepHandler = (TimeInterval) -> Void

public func runOpenComputerUseCall(
    _ invocation: OpenComputerUseCallInvocation,
    service: ComputerUseService = ComputerUseService(),
    sleepHandler: OpenComputerUseSleepHandler = { Thread.sleep(forTimeInterval: $0) }
) throws -> OpenComputerUseCallOutput {
    let dispatcher = ComputerUseToolDispatcher(service: service)

    switch invocation {
    case let .single(toolName, argumentsJSON, argumentsFile):
        let arguments = try readOpenComputerUseToolArguments(
            json: argumentsJSON,
            file: argumentsFile
        )
        let result = dispatcher.callToolAsResult(name: toolName, arguments: arguments)
        return OpenComputerUseCallOutput(
            jsonObject: result.asDictionary,
            hasToolError: result.isError
        )

    case let .sequence(callsJSON, callsFile, interCallDelay):
        let calls = try readOpenComputerUseCallSequence(json: callsJSON, file: callsFile)
        var outputs: [[String: Any]] = []
        var hasToolError = false

        for (index, call) in calls.enumerated() {
            let result = dispatcher.callToolAsResult(name: call.tool, arguments: call.arguments)
            outputs.append([
                "tool": call.tool,
                "result": result.asDictionary,
            ])

            if result.isError {
                hasToolError = true
                break
            }

            if index < calls.count - 1, interCallDelay > 0 {
                sleepHandler(interCallDelay)
            }
        }

        return OpenComputerUseCallOutput(jsonObject: outputs, hasToolError: hasToolError)
    }
}

public func readOpenComputerUseToolArguments(
    json: String?,
    file: String?
) throws -> [String: Any] {
    guard let source = try readOpenComputerUseJSONSource(json: json, file: file) else {
        return [:]
    }

    let object = try decodeOpenComputerUseJSONObject(source)
    guard let arguments = object as? [String: Any] else {
        throw OpenComputerUseCLIError(message: "--args must be a JSON object", helpCommand: "call")
    }

    return arguments
}

public func readOpenComputerUseCallSequence(
    json: String?,
    file: String?
) throws -> [OpenComputerUseCallSpec] {
    guard let source = try readOpenComputerUseJSONSource(json: json, file: file) else {
        throw OpenComputerUseCLIError(message: "call sequence requires --calls or --calls-file", helpCommand: "call")
    }

    let object = try decodeOpenComputerUseJSONObject(source)
    guard let array = object as? [Any] else {
        throw OpenComputerUseCLIError(message: "--calls must be a JSON array", helpCommand: "call")
    }

    return try array.enumerated().map { index, item in
        guard let dictionary = item as? [String: Any] else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) must be a JSON object",
                helpCommand: "call"
            )
        }

        guard let tool = (dictionary["tool"] ?? dictionary["name"]) as? String, !tool.isEmpty else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) requires a non-empty tool",
                helpCommand: "call"
            )
        }

        let rawArguments = dictionary["args"] ?? dictionary["arguments"] ?? [:]
        guard let arguments = rawArguments as? [String: Any] else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) args must be a JSON object",
                helpCommand: "call"
            )
        }

        return OpenComputerUseCallSpec(tool: tool, arguments: arguments)
    }
}

private func readOpenComputerUseJSONSource(json: String?, file: String?) throws -> String? {
    if json != nil, file != nil {
        throw OpenComputerUseCLIError(message: "Use either inline JSON or a JSON file, not both", helpCommand: "call")
    }

    if let json {
        return json
    }

    guard let file else {
        return nil
    }

    do {
        return try String(contentsOfFile: file, encoding: .utf8)
    } catch {
        throw OpenComputerUseCLIError(
            message: "Unable to read JSON file \(file): \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

private func decodeOpenComputerUseJSONObject(_ source: String) throws -> Any {
    guard let data = source.data(using: .utf8) else {
        throw OpenComputerUseCLIError(message: "JSON input must be UTF-8 text", helpCommand: "call")
    }

    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw OpenComputerUseCLIError(
            message: "Invalid JSON input: \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

func validatedQueryWindowID(_ value: Any?) throws -> CGWindowID? {
    guard let value else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 1,
          number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded(.down) == number.doubleValue else {
        throw ComputerUseError.invalidArguments("window_id must be an integer from 1 to \(UInt32.max)")
    }
    return CGWindowID(number.doubleValue)
}

func validatedQueryString(_ value: Any?, key: String) throws -> String? {
    guard let value else { return nil }
    guard let string = value as? String, string.utf16.count <= 1000 else {
        throw ComputerUseError.invalidArguments("\(key) must be a string of at most 1000 UTF-16 code units")
    }
    return string
}

func validatedQueryExact(_ value: Any?) throws -> Bool {
    guard let value else { return false }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw ComputerUseError.invalidArguments("exact must be true or false")
    }
    return number.boolValue
}
