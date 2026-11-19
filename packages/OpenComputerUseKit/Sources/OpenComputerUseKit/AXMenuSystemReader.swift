import ApplicationServices
import Foundation

/// 活动菜单发现的时间预算（秒）。
enum AXMenuDiscoveryBudget {
    /// 还没发现任何菜单候选时的总预算：没有菜单的常规快照只多付这么多。
    static let discovery: TimeInterval = 0.08
    /// 发现候选后 discovery + 复核的总预算。
    static let withCandidate: TimeInterval = 0.3
    /// 单次 AX IPC 上限。
    static let perCall: TimeInterval = 0.04
    /// 菜单树的最少节点上限：历史 / 书签 / 字体这类长菜单不能默默继承快照的 256 节点上限；
    /// 调用方给得更多时用调用方的。时间预算不变，仍是真正的硬上限。
    static let minimumNodes = 2048
    /// 进入遍历时剩余预算里要给复核留下的比例：复核对每个节点再读两次，约为遍历开销的一半。
    static let verificationShare = 0.4
}

/// 遍历预算：第一次询问时记下当时的剩余预算，之后剩余低于 `verificationShare` 即视为遍历该停，
/// 其余时间留给逐节点复核。
struct AXMenuWalkBudget {
    private var startRemaining: TimeInterval?

    mutating func exhausted(remaining: TimeInterval) -> Bool {
        if startRemaining == nil { startRemaining = remaining }
        return remaining < (startRemaining ?? remaining) * AXMenuDiscoveryBudget.verificationShare
    }
}

/// AXUIElement 实现的只读菜单读取器：每次 IPC 都带剩余预算的超时，预算耗尽后一律返回空。
struct AXMenuSystemReader {
    let remaining: () -> TimeInterval

    func prepare(_ element: AXUIElement) -> Bool {
        let interval = remaining()
        return interval > 0
            && AXUIElementSetMessagingTimeout(element, Float(min(interval, AXMenuDiscoveryBudget.perCall))) == .success
    }

    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success,
              remaining() > 0 else { return nil }
        return result
    }

    func element(_ root: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(root, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(result, to: AXUIElement.self)
    }

    func owner(_ element: AXUIElement) -> pid_t? {
        var result: pid_t = 0
        return AXUIElementGetPid(element, &result) == .success ? result : nil
    }

    func array(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard prepare(element) else { return [] }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) == .success,
              count > 0, prepare(element) else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, min(count, 256), &values) == .success,
              remaining() > 0 else { return [] }
        return (values as? [AXUIElement]) ?? []
    }

    func frame(_ root: AXUIElement) -> CGRect? {
        guard let position = value(root, kAXPositionAttribute), let size = value(root, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func windows(pid: pid_t) -> [AXMenuWindowEvidence] {
        guard remaining() > 0,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
              as? [[String: Any]],
              remaining() > 0 else { return [] }
        return infos.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid,
                  let identifier = info[kCGWindowNumber as String] as? NSNumber,
                  let rect = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rect),
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber,
                  let visible = info[kCGWindowIsOnscreen as String] as? NSNumber else { return nil }
            return AXMenuWindowEvidence(windowID: identifier.uint32Value, pid: pid, bounds: bounds,
                                        layer: layer.intValue, onScreen: visible.boolValue,
                                        alpha: alpha.doubleValue)
        }
    }
}
