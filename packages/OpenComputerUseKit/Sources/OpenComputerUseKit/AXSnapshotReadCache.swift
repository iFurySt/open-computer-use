import ApplicationServices
import Foundation

/// Per-snapshot cache for the accessibility reads made by the tree renderer.
///
/// The first read of an element fetches the attributes the renderer commonly uses with one
/// `AXUIElementCopyMultipleAttributeValues` call. Successful and unsupported/no-value results
/// are kept for the rest of that walk; transient errors are not kept. Only the renderer
/// enters this scope: action reads, rewalks and later snapshots always read fresh values.
/// `OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE=1` turns the cache off for output comparison.
final class AXSnapshotReadCache: NSObject {
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    enum Attribute {
        case value(CFTypeRef)
        case absent
        var value: CFTypeRef? { if case .value(let value) = self { return value }; return nil }
    }
    static let key = "OpenComputerUse.AXSnapshotReadCache"
    static var current: AXSnapshotReadCache? { Thread.current.threadDictionary[key] as? AXSnapshotReadCache }
    private var attributes: [ElementKey: [String: Attribute]] = [:]
    private var prefetched: Set<ElementKey> = []
    private var actions: [ElementKey: [String]] = [:]
    private var settable: [ElementKey: [String: Bool]] = [:]
    let batch: (AXUIElement) -> [String: Attribute]
    let single: (AXUIElement, String) -> (AXError, CFTypeRef?)
    let readActions: (AXUIElement) -> (AXError, [String]?)
    let readSettable: (AXUIElement, String) -> (AXError, Bool)

    init(batch: @escaping (AXUIElement) -> [String: Attribute] = readBatch,
         single: @escaping (AXUIElement, String) -> (AXError, CFTypeRef?) = readSingle,
         actions: @escaping (AXUIElement) -> (AXError, [String]?) = readActionNames,
         settable: @escaping (AXUIElement, String) -> (AXError, Bool) = readIsSettable) {
        self.batch = batch; self.single = single
        self.readActions = actions; self.readSettable = settable
    }

    static func withSnapshot<T>(_ body: () throws -> T) rethrows -> T {
        let cache = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_DISABLE_AX_READ_CACHE"] == "1"
            ? nil : AXSnapshotReadCache()
        return try withCache(cache, body)
    }

    static func withCache<T>(_ cache: AXSnapshotReadCache?, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = cache
        defer { dictionary[key] = previous }
        return try body()
    }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let key = ElementKey(element: element)
        if prefetched.insert(key).inserted { attributes[key] = batch(element) }
        if let cached = attributes[key]?[name] { return cached.value }
        let (error, value) = single(element, name)
        if error == .success, let value { attributes[key, default: [:]][name] = .value(value); return value }
        if error == .attributeUnsupported || error == .noValue { attributes[key, default: [:]][name] = .absent }
        return nil // Transient errors are not retained.
    }

    func actionNames(_ element: AXUIElement) -> [String]? {
        let key = ElementKey(element: element)
        if let cached = actions[key] { return cached }
        let (error, raw) = readActions(element)
        if error == .success { let names = raw ?? []; actions[key] = names; return names }
        return nil
    }

    func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        let key = ElementKey(element: element)
        if let cached = settable[key]?[name] { return cached }
        let (error, flag) = readSettable(element, name)
        let result = error == .success && flag
        if error == .success || error == .attributeUnsupported { settable[key, default: [:]][name] = result }
        return result
    }

    private static func readActionNames(_ element: AXUIElement) -> (AXError, [String]?) {
        var raw: CFArray?
        let error = AXUIElementCopyActionNames(element, &raw)
        return (error, raw as? [String])
    }

    private static func readIsSettable(_ element: AXUIElement, _ name: String) -> (AXError, Bool) {
        var flag = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, name as CFString, &flag)
        return (error, flag.boolValue)
    }

    private static let names = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXHelp", "AXValue",
        "AXIdentifier", "AXSelected", "AXExpanded", "AXEnabled", "AXPlaceholderValue", "AXPlaceholder",
        "AXPosition", "AXSize", "AXURL", "AXChildren", "AXRows", "AXVisibleChildren", "AXContents",
    ]

    private static func readSingle(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private static func readBatch(_ element: AXUIElement) -> [String: Attribute] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard error == .success, let raw = values as? [AnyObject], raw.count == names.count else { return [:] }
        var result: [String: Attribute] = [:]
        for (name, value) in zip(names, raw) {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var failure = AXError.failure
                if AXValueGetValue(value as! AXValue, .axError, &failure), failure == .attributeUnsupported || failure == .noValue {
                    result[name] = .absent
                }
            } else if !(value is NSNull) { result[name] = .value(value) }
        }
        return result
    }
}
