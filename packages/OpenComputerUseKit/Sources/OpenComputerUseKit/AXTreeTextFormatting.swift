import Foundation

/// Compact text retains all nodes and fields. Only their spelling and whitespace
/// change; action records and the predicates that choose nodes use the raw data.
enum AXTreeIndentationStyle: String {
    case level
    case tab4

    /// One tab per tree level is the default. In a two-model comprehension test it was the
    /// only indentation both models read without error; `tab4` packs four levels into one
    /// tab and is opt-in via `OPEN_COMPUTER_USE_AX_INDENTATION=tab4`. Unknown values use the default.
    static var current: Self {
        Self(rawValue: ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_AX_INDENTATION"] ?? "") ?? .level
    }
}

enum AXTreeTextFormatting {
    static func legend(for style: AXTreeIndentationStyle) -> String {
        style == .level ? "[w=settable]" : "[tab=4 w=settable]"
    }

    static func indentation(_ depth: Int, compact: Bool, style: AXTreeIndentationStyle = .tab4) -> String {
        guard compact && style == .tab4 else { return String(repeating: "\t", count: depth) }
        return String(repeating: "\t", count: depth / 4) + String(repeating: " ", count: depth % 4)
    }

    static func traitTokens(_ traits: [String], compact: Bool) -> [String] {
        guard compact else { return traits }
        let types = ["string": "str", "boolean": "bool", "float": "float"]
        var result: [String] = [], index = 0
        while index < traits.count {
            if traits[index] == "settable" {
                if index + 1 < traits.count, let type = types[traits[index + 1]] {
                    result.append("w:\(type)"); index += 2; continue
                }
                result.append("w")
            } else { result.append(traits[index]) }
            index += 1
        }
        return result
    }

    static func role(_ role: String, compact: Bool) -> String {
        compact && role == "container" ? "group" : role
    }

    static func valueSegment(_ segment: String, compact: Bool) -> String {
        guard compact, segment.hasPrefix(" Value: ") else { return segment }
        return " = " + segment.dropFirst(" Value: ".count)
    }
}
