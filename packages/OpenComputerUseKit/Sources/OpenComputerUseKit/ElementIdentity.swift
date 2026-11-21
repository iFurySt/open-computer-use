import ApplicationServices
import Foundation

/// Which control a snapshot showed at an index: its role, subrole, name (title, else description) and identifier,
/// and its value only where the value is what names it (static text, a pop-up's shown choice). A field's value is
/// what was typed into it and a checkbox's is its state; they change every time the control is used, so they are
/// left out.
struct ElementIdentity: Equatable {
    let role: String?
    let subrole: String?
    let name: String?
    let identifier: String?
    let value: String?

    static let valueIsName: Set<String> = [kAXStaticTextRole as String, kAXPopUpButtonRole as String]

    init(role: String?, subrole: String?, title: String?, description: String?, identifier: String?, value: String?) {
        func text(_ string: String?) -> String? {
            string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        self.role = text(role)
        self.subrole = text(subrole)
        name = text(title) ?? text(description)
        self.identifier = text(identifier)
        self.value = role.map(Self.valueIsName.contains) == true ? text(value) : nil
    }

    var described: String {
        [role, name.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
    }

    static func validate(index: String, recorded: ElementIdentity, now: ElementIdentity?) throws {
        guard recorded.role != nil, now == recorded else {
            throw ComputerUseError.stateUnavailable(
                "element \(index) no longer has the identity the snapshot showed, or could not be checked; call get_app_state again (nothing was sent)"
            )
        }
    }

    enum AttributeReading: Equatable {
        case text(String)
        case absent
        case unreadable
    }

    /// One entry from AXUIElementCopyMultipleAttributeValues, read the way the snapshot reads the same attribute
    /// (AXUIElementCopyAttributeValue, where any AX error means no value). Some controls answer an attribute they
    /// don't carry with kAXErrorFailure rather than attributeUnsupported (TextEdit's text area on macOS 27 does
    /// for AXDescription); counting only attributeUnsupported/noValue as absent made those controls fail every
    /// check while their snapshot recorded nil. The role is still required by the caller.
    static func reading(_ value: AnyObject) -> AttributeReading {
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
            var error = AXError.success
            return AXValueGetValue(value as! AXValue, .axError, &error) ? .absent : .unreadable
        }
        if let text = value as? String { return .text(text) }
        return value is NSNull ? .absent : .unreadable
    }

    /// Read identity without walking or rebinding to a different, same-named control.
    /// Read the current role/subrole before requesting any value, preserving password protection.
    static func read(_ element: AXUIElement) throws -> ElementIdentity? {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] as [String]
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard result == .success, let list = values as? [AnyObject], list.count == names.count else { return nil }
        var read: [String: String] = [:]
        for (name, value) in zip(names, list) {
            switch reading(value) {
            case .text(let text): read[name] = text
            case .absent: continue
            case .unreadable: return nil
            }
        }
        let role = read[kAXRoleAttribute], subrole = read[kAXSubroleAttribute]
        guard role != nil else { return nil }
        var value: String?
        if valueIsName.contains(role!), !isSecureTextField(subrole: subrole) {
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw)
            guard error == .success || error == .attributeUnsupported || error == .noValue else { return nil }
            value = raw as? String
        }
        return ElementIdentity(role: role, subrole: subrole, title: read[kAXTitleAttribute],
                               description: read[kAXDescriptionAttribute], identifier: read[kAXIdentifierAttribute], value: value)
    }
}
