import Foundation

/// The outcome of comparing the value requested from `set_value` with the
/// values read back from the accessibility element around the write.
enum SetValueReadBackResult: Equatable {
    /// The element reports the requested value after the write.
    case verified
    /// The element still reports the value it had before the write.
    case unchanged(actual: String?)
    /// The element reports a different value than the one requested.
    case mismatched(actual: String?)
}

/// Compares the requested value with the value read back after an accessibility
/// write. `before` may be nil when the element did not expose a readable value.
///
/// Values are compared after trimming whitespace, as numbers when both sides
/// parse as a number (so `15` matches `15.0`), and as booleans for the
/// `true`/`false`/`1`/`0` literals that `CFBoolean` produces.
func setValueReadBackResult(requested: String, before: String?, after: String?) -> SetValueReadBackResult {
    guard let after else { return .unchanged(actual: nil) }
    if setValueValuesMatch(requested, after) { return .verified }
    if let before, setValueValuesMatch(before, after) {
        // A write that only repeats the current value is a successful no-op:
        // the element already reports what the caller asked for.
        if setValueValuesMatch(requested, before) { return .verified }
        return .unchanged(actual: after)
    }
    return .mismatched(actual: after)
}

/// Whether two accessibility value strings denote the same value. Exact match
/// first, then numeric equality (`15` == `15.0`), then boolean equality so a
/// `CFBoolean` read back as `true` matches a requested `1`.
func setValueValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    if left == right { return true }
    if let leftNumber = Double(left), let rightNumber = Double(right) {
        return leftNumber == rightNumber
    }
    if let leftBool = setValueBooleanLiteral(left), let rightBool = setValueBooleanLiteral(right) {
        return leftBool == rightBool
    }
    return false
}

/// Converts an AX value into the string used for read-back comparison. The
/// accessibility API hands back `CFString`, `CFNumber` and `CFBoolean`
/// depending on the control, so all three are supported.
func setValueReadBackString(from value: CFTypeRef) -> String? {
    if CFGetTypeID(value) == CFStringGetTypeID() {
        return (value as? String)
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false"
    }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        // Keep integer-valued controls ("15") from reading back as "15.0".
        if doubleValue.isFinite, doubleValue == doubleValue.rounded(),
           abs(doubleValue) < 9_007_199_254_740_992 {
            return String(number.int64Value)
        }
        return String(doubleValue)
    }
    return nil
}

/// The error reported when the AX write succeeds but the element does not
/// report the requested value. Nil means the outcome is acceptable.
func setValueReadBackErrorMessage(elementIndex: String, requested: String, result: SetValueReadBackResult) -> String? {
    switch result {
    case .verified:
        return nil
    case .unchanged(let actual):
        let current = actual.map { "still reports \"\($0)\"" } ?? "does not expose a readable value"
        return "set_value failed: macOS accepted the AX write, but element \(elementIndex) \(current) instead of \"\(requested)\". The control may not support programmatic value changes; click it and use type_text or its own actions instead."
    case .mismatched(let actual):
        let current = actual.map { "reports \"\($0)\"" } ?? "does not expose a readable value"
        return "set_value failed: macOS accepted the AX write, but element \(elementIndex) \(current) instead of \"\(requested)\". The control may normalize or reject this value."
    }
}

private func setValueBooleanLiteral(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "true", "yes", "1":
        return true
    case "false", "no", "0":
        return false
    default:
        return nil
    }
}
