import Foundation

/// Text stays literal. Numeric/boolean coercion is allowed only when AX itself
/// returns that type, never merely because a text field looks like a number.
func setValueMatches(requested: String, actual: CFTypeRef?) -> Bool {
    guard let actual else { return false }
    if CFGetTypeID(actual) == CFStringGetTypeID(), let text = actual as? String {
        return requested.utf16.elementsEqual(text.utf16)
    }
    if CFGetTypeID(actual) == CFBooleanGetTypeID() {
        let literal = requested.lowercased()
        let expected: Bool?
        switch literal {
        case "true", "1": expected = true
        case "false", "0": expected = false
        default: expected = nil
        }
        return expected == CFBooleanGetValue((actual as! CFBoolean))
    }
    if CFGetTypeID(actual) == CFNumberGetTypeID(), let number = actual as? NSNumber {
        guard let expected = normalizedSetValueNumber(requested), let observed = normalizedSetValueNumber(number.stringValue) else { return false }
        return expected == observed
    }
    return false
}

private struct SetValueNumber: Equatable {
    let negative: Bool
    let digits: String
    let exponent: Int
}

/// Normalize decimal spelling without rounding through Double or Decimal.
/// This preserves large integers and the full exponent range of AX numbers.
private func normalizedSetValueNumber(_ text: String) -> SetValueNumber? {
    let parts = text.lowercased().split(separator: "e", omittingEmptySubsequences: false)
    guard let first = parts.first, parts.count <= 2 else { return nil }
    var mantissa = String(first)
    let negative = mantissa.first == "-"
    if mantissa.first == "-" || mantissa.first == "+" { mantissa.removeFirst() }
    let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    guard decimal.count <= 2 else { return nil }
    let digits = decimal.joined()
    guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    let explicitExponent: Int
    if parts.count == 2 {
        guard let value = Int(parts[1]) else { return nil }
        explicitExponent = value
    } else { explicitExponent = 0 }
    let fractionCount = decimal.count == 2 ? decimal[1].count : 0
    let (exponent, overflow) = explicitExponent.subtractingReportingOverflow(fractionCount)
    guard !overflow else { return nil }
    var significant = String(digits.drop(while: { $0 == "0" }))
    if significant.isEmpty { return .init(negative: false, digits: "0", exponent: 0) }
    var trailing = 0
    while significant.last == "0" { significant.removeLast(); trailing += 1 }
    let (adjusted, adjustmentOverflow) = exponent.addingReportingOverflow(trailing)
    guard !adjustmentOverflow else { return nil }
    return .init(negative: negative, digits: significant, exponent: adjusted)
}

func verifySetValueReadBack(
    requested: String,
    elementIndex: String,
    read: () -> CFTypeRef?,
    validate: () throws -> Void,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
) throws {
    let deadline = now() + 0.6
    while true {
        try validate()
        let matches = setValueMatches(requested: requested, actual: read())
        try validate()
        if matches { return }
        let remaining = deadline - now()
        guard remaining > 0 else {
            throw ComputerUseError.message("set_value could not verify the requested value for element \(elementIndex). Read the current value before retrying; the write may have changed the control.")
        }
        sleep(min(0.05, remaining))
    }
}
