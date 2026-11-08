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

    /// The element to act on for `index`: nil while the kept element still reads as `recorded`, else the one
    /// current element that does. None, several, or a search that was cut short throws before anything is sent:
    /// never the first of several, never by position. `candidates` runs only on a mismatch.
    static func rebind<Element>(
        index: String,
        recorded: ElementIdentity,
        now: ElementIdentity?,
        candidates: () -> (found: [(element: Element, identity: ElementIdentity)], complete: Bool)
    ) throws -> Element? {
        guard now != recorded else { return nil }
        let search = candidates()
        let same = search.found.filter { $0.identity == recorded }
        guard same.count == 1, search.complete, let only = same.first else {
            let count = same.isEmpty ? "no element now is" : "\(same.count)\(search.complete ? "" : " or more") elements now are"
            throw ComputerUseError.stateUnavailable(
                "element \(index) is no longer the \(recorded.described) the snapshot showed, and \(count); call get_app_state again (nothing was sent)"
            )
        }
        return only.element
    }

    /// What `element` reads as now, with its children when asked, in one batched message; nil when it is gone.
    /// Throws when the app doesn't answer, so a busy app is never read as a changed control.
    static func read(_ element: AXUIElement, valueToo: Bool, children: Bool = false) throws -> (identity: ElementIdentity, children: [AXUIElement])? {
        var names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute] as [String]
        if valueToo { names.append(kAXValueAttribute) }
        if children { names.append(kAXChildrenAttribute) }
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        if result == .cannotComplete {
            throw ComputerUseError.message("the app did not answer the check before the action, so nothing was sent. Try again once it responds.")
        }
        guard result == .success, let list = values as? [AnyObject], list.count == names.count else { return nil }
        let read = Dictionary(uniqueKeysWithValues: zip(names, list))
        let identity = ElementIdentity(
            role: read[kAXRoleAttribute] as? String, subrole: read[kAXSubroleAttribute] as? String,
            title: read[kAXTitleAttribute] as? String, description: read[kAXDescriptionAttribute] as? String,
            identifier: read[kAXIdentifierAttribute] as? String, value: read[kAXValueAttribute] as? String
        )
        return (identity, read[kAXChildrenAttribute] as? [AXUIElement] ?? [])
    }

    /// Every element under `root` with its identity, breadth first, at most `cap` nodes within `seconds`.
    /// `complete` is false when the cap or the time cut the search, or the app stopped answering part way.
    static func walk(
        _ root: AXUIElement,
        valueToo: Bool,
        cap: Int = AccessibilityTreeLimits.defaultMaxNodeCount,
        seconds: TimeInterval = 2
    ) -> (found: [(element: AXUIElement, identity: ElementIdentity)], complete: Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var queue = [root], head = 0
        var found: [(element: AXUIElement, identity: ElementIdentity)] = []
        while head < queue.count {
            guard head < cap, ProcessInfo.processInfo.systemUptime < deadline else { return (found, false) }
            guard let node = try? read(queue[head], valueToo: valueToo, children: true) else { return (found, false) }
            found.append((queue[head], node.identity))
            queue += node.children
            head += 1
        }
        return (found, true)
    }
}
