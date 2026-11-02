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
        guard let expected = setValueDecimal(requested), let observed = setValueDecimal(number.stringValue) else { return false }
        return expected == observed
    }
    return false
}

private func setValueDecimal(_ text: String) -> Decimal? {
    guard text.filter({ $0.isNumber }).count <= 38,
          let range = text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression), range.upperBound == text.endIndex,
          let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
    return value
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
