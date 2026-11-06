import ApplicationServices
import Foundation

/// 只读依赖，测试不需要真实应用或系统 AX 权限。
struct AXMenuReader<Element> {
    var owner: (Element) -> pid_t?
    var role: (Element) -> String?
    var selected: (Element) -> Bool
    var visible: (Element) -> Bool?
    var expanded: (Element) -> Bool?
    var frame: (Element) -> CGRect?
    var parent: (Element) -> Element?
    var children: (Element, String) -> [Element]
    var equal: (Element, Element) -> Bool
}

struct AXActiveMenuTree<Element> {
    var roots: [Element] = []
    var entries: [(element: Element, children: [Element])] = []

    func children(of element: Element, equal: (Element, Element) -> Bool) -> [Element]? {
        entries.first(where: { equal($0.element, element) })?.children
    }
}

/// 几何只用于只读菜单可见性佐证，不证明窗口所有权，也不授权输入。
struct AXMenuWindowEvidence {
    var windowID: CGWindowID
    var pid: pid_t
    var bounds: CGRect
    var layer: Int
    var onScreen: Bool
    var alpha: Double

    func matches(_ frame: CGRect, pid: pid_t, excluding rootWindowID: CGWindowID) -> Bool {
        func valid(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 0 && rect.height > 0
        }
        guard self.pid == pid, windowID != 0, windowID != rootWindowID,
              onScreen, alpha.isFinite, alpha > 0, layer > 0, valid(frame), valid(bounds) else { return false }
        // CG/AX 均为全局 point。菜单窗口（layer > 0）在 macOS 26+ 带玻璃/阴影内边距：
        // AX 报的是菜单内容区，CG 报的是整个窗口，四边各差约 75pt（Contacts 实测）。
        // 只接受"内容区被窗口包含且每边边距有限"，仍拒绝普通窗口的包含或仅相交。
        let insets = [frame.minX - bounds.minX, frame.minY - bounds.minY,
                      bounds.maxX - frame.maxX, bounds.maxY - frame.maxY]
        return insets.allSatisfy { $0 >= -2 && $0 <= Self.maximumMenuWindowInset }
    }

    /// 菜单窗口内容区到窗口边缘的最大可信边距（pt）。
    static let maximumMenuWindowInset: CGFloat = 96
}

private struct AXMenuGeometry<Element> {
    let element: Element
    let frame: CGRect
    let window: AXMenuWindowEvidence
}

private struct AXMenuSelectionReader<Element> {
    let menuBar: Element?
    let pid: pid_t
    let maximumDepth: Int
    let reader: AXMenuReader<Element>

    private func contains(_ list: [Element], _ element: Element) -> Bool {
        list.contains { reader.equal($0, element) }
    }

    private func owned(_ element: Element, expired: () -> Bool) -> Bool {
        !expired() && reader.owner(element) == pid
    }

    private func focusedSelection(
        focused: () -> Element?, expired: () -> Bool
    ) -> (menu: Element?, ancestors: [Element]) {
        let menu = kAXMenuRole as String
        let item = kAXMenuItemRole as String
        let barItem = kAXMenuBarItemRole as String
        var ancestors: [Element] = []
        var current = focused()
        var focusedMenu: Element?
        // 焦点项自身的 expanded=false 只代表没有展开子菜单，不否定其父菜单。
        for _ in 0 ..< maximumDepth {
            guard let element = current else { break }
            guard owned(element, expired: expired) else { ancestors = []; focusedMenu = nil; break }
            guard !contains(ancestors, element), let role = reader.role(element),
                  [menu, item, barItem].contains(role) else { break }
            guard reader.visible(element) != false,
                  !(focusedMenu != nil && role != menu && reader.expanded(element) == false)
            else { ancestors = []; focusedMenu = nil; break }
            ancestors.append(element)
            if role == menu { focusedMenu = element }
            current = reader.parent(element)
        }
        return (focusedMenu, ancestors)
    }

    func selection(
        focused: () -> Element?, expired: () -> Bool, foundCandidate: () -> Void,
        children: (Element) -> [Element], isOpen: (Element, Element, [Element]) -> Bool
    ) -> (roots: [Element], ancestors: [Element]) {
        let barItem = kAXMenuBarItemRole as String
        var roots: [Element] = []
        var (focusedMenu, ancestors) = focusedSelection(focused: focused, expired: expired)
        if let focusedMenu, !expired() {
            foundCandidate()
            roots.append(focusedMenu)
        }
        if let menuBar, owned(menuBar, expired: expired), reader.role(menuBar) == kAXMenuBarRole as String {
            let selected = Array(reader.children(menuBar, kAXSelectedChildrenAttribute).prefix(32))
            // 常规无菜单路径不读取每个 menubar item 的子树。
            let items = selected.isEmpty ? Array(reader.children(menuBar, kAXChildrenAttribute).prefix(32)) : selected
            for child in items where owned(child, expired: expired) && reader.role(child) == barItem {
                // 菜单栏把它列进 AXSelectedChildren、或它就是焦点链的一环，都说明系统正在跟踪这个菜单；
                // 此时 AXExpanded=false 不可信（macOS 27 的 Contacts 菜单打开时仍报 false）。
                let attested = contains(selected, child) || contains(ancestors, child)
                guard reader.selected(child) || attested,
                      reader.visible(child) != false, reader.expanded(child) != false || attested, !expired()
                else { continue }
                if attested, !contains(ancestors, child) { ancestors.append(child) }
                foundCandidate()
                for candidate in children(child) {
                    if isOpen(candidate, child, ancestors), !contains(roots, candidate) {
                        roots.append(candidate)
                    }
                }
            }
        }
        return (roots, ancestors)
    }
}

// 活动菜单是主窗口的附加语义树，不替换窗口身份或授权任何输入。
// 嵌套遍历与复核共享同轮预算/几何缓存，保留同步非逃逸回调，避免拆分后改变生命周期。
// swiftlint:disable:next function_body_length cyclomatic_complexity
func readActiveAXMenus<Element>(
    menuBar: Element?, focused: () -> Element?, pid: pid_t,
    maximumNodes: Int = 256, maximumDepth: Int = 16,
    expired: () -> Bool = { false },
    foundCandidate: () -> Void = {},
    rootWindowID: CGWindowID = 0,
    windowEvidence: () -> [AXMenuWindowEvidence] = { [] },
    prepareForPublication: (Element) -> Bool = { _ in true },
    validateWindow: () -> Bool,
    reader: AXMenuReader<Element>
) -> AXActiveMenuTree<Element> {
    guard maximumNodes > 0, maximumDepth > 0, !expired() else { return .init() }
    let menu = kAXMenuRole as String
    let item = kAXMenuItemRole as String
    var windows: [AXMenuWindowEvidence]?
    var geometry: [AXMenuGeometry<Element>] = []
    func contains(_ list: [Element], _ element: Element) -> Bool {
        list.contains { reader.equal($0, element) }
    }
    func owned(_ element: Element) -> Bool {
        !expired() && reader.owner(element) == pid
    }
    func geometricEvidence(_ element: Element) -> Bool {
        guard owned(element), let frame = reader.frame(element), !expired() else { return false }
        if let previous = geometry.first(where: { reader.equal($0.element, element) }), previous.frame != frame {
            return false
        }
        // 初次几何匹配复用一次 CG 列表，结束前再批量复核一次；无候选时不查询。
        if windows == nil { windows = windowEvidence().filter { $0.pid == pid } }
        let matches = windows?.filter { $0.matches(frame, pid: pid, excluding: rootWindowID) } ?? []
        guard !expired(), matches.count == 1, let match = matches.first else { return false }
        if !geometry.contains(where: { reader.equal($0.element, element) }) {
            geometry.append(AXMenuGeometry(element: element, frame: frame, window: match))
        }
        return true
    }
    func children(_ element: Element) -> [Element] {
        var result: [Element] = []
        for attribute in [kAXChildrenAttribute, "AXVisibleChildren", kAXSelectedChildrenAttribute] {
            guard !expired() else { return [] }
            for child in reader.children(element, attribute).prefix(maximumNodes) {
                guard result.count < maximumNodes else { return result }
                if owned(child), !contains(result, child) { result.append(child) }
            }
        }
        return result
    }
    func isOpen(_ candidate: Element, parent: Element, ancestors: [Element]) -> Bool {
        // 父项在 ancestors 里（焦点链或菜单栏 AXSelectedChildren 认证）时，其 AXExpanded=false 不作数；
        // 菜单本身是否打开仍要下面的独立证据。
        guard owned(candidate), reader.role(candidate) == menu,
              reader.visible(candidate) != false, reader.visible(parent) != false,
              reader.expanded(parent) != false || contains(ancestors, parent), !expired() else { return false }
        foundCandidate()
        if reader.visible(candidate) == true || reader.expanded(parent) == true || contains(ancestors, candidate) {
            return !expired()
        }
        if contains(reader.children(parent, "AXVisibleChildren"), candidate) { return !expired() }
        return geometricEvidence(candidate)
    }
    func selection() -> (roots: [Element], ancestors: [Element]) {
        AXMenuSelectionReader(menuBar: menuBar, pid: pid, maximumDepth: maximumDepth, reader: reader)
            .selection(focused: focused, expired: expired, foundCandidate: foundCandidate,
                       children: children, isOpen: isOpen)
    }

    let initial = selection()
    guard !expired(), !initial.roots.isEmpty, validateWindow(), !expired() else { return .init() }
    var tree = AXActiveMenuTree<Element>()
    var seen: [Element] = []
    func walk(_ element: Element, depth: Int) -> Bool {
        guard depth < maximumDepth, seen.count < maximumNodes, owned(element), reader.visible(element) != false,
              !contains(seen, element), let role = reader.role(element), [menu, item].contains(role)
        else { return false }
        seen.append(element)
        var descendants: [Element] = []
        // 只探索活动项的候选子菜单；每层仍须独立证明打开，selected 本身不够。
        if role == menu || reader.expanded(element) == true || reader.selected(element)
            || contains(initial.ancestors, element) {
            for child in children(element) {
                if reader.role(child) == menu,
                   !isOpen(child, parent: element, ancestors: initial.ancestors) { continue }
                if walk(child, depth: depth + 1) { descendants.append(child) }
            }
        }
        tree.entries.append((element, descendants))
        return true
    }
    for root in initial.roots where walk(root, depth: 0) {
        tree.roots.append(root)
    }
    let final = selection()
    guard !expired(), validateWindow(), !expired(), initial.roots.count == final.roots.count,
          zip(initial.roots, final.roots).allSatisfy({ reader.equal($0.0, $0.1) }) else { return .init() }
    for entry in tree.entries {
        guard owned(entry.element), reader.visible(entry.element) != false else { return .init() }
        for child in entry.children where reader.role(child) == menu {
            guard isOpen(child, parent: entry.element, ancestors: final.ancestors) else { return .init() }
        }
    }
    for evidence in geometry {
        guard owned(evidence.element), reader.frame(evidence.element) == evidence.frame else { return .init() }
    }
    if !geometry.isEmpty {
        guard !expired() else { return .init() }
        let freshWindows = windowEvidence()
        guard !expired(), geometry.allSatisfy({ evidence in
            let matches = freshWindows.filter { $0.matches(evidence.frame, pid: pid, excluding: rootWindowID) }
            guard matches.count == 1, let window = matches.first else { return false }
            return window.windowID == evidence.window.windowID && window.bounds == evidence.window.bounds
                && window.layer == evidence.window.layer
        }) else { return .init() }
    }
    // 发布的同一批句柄会被 renderer/AXPress 复用，不能携带 discovery 的短超时。
    for entry in tree.entries {
        guard !expired(), prepareForPublication(entry.element) else { return .init() }
    }
    return expired() ? .init() : tree
}

/// 无候选 discovery 预算 80ms，有候选后 discovery/复核总预算 300ms；每次 AX IPC 至多 40ms。
/// 预算不能太紧：画中画用 ScreenCaptureKit 录目标窗口时，Contacts 这类 SwiftUI 应用的 AX 响应
/// 会从 <1ms 涨到 20–30ms，原来的 4ms 上限让菜单栏读取一律超时、菜单永远读不到。
/// CG 同步查询返回后检查预算；后续语义渲染沿用普通 AX renderer 的约束。
/// 只给本次创建/取得的 AX 句柄设置超时，不接收共享 snapshot root。
func captureActiveAXMenus(
    pid: pid_t, windowID: CGWindowID, bounds: CGRect, maximumNodes: Int
) -> AXActiveMenuTree<AXUIElement> {
    let started = ProcessInfo.processInfo.systemUptime
    var duration: TimeInterval = AXMenuDiscoveryBudget.discovery
    func remaining() -> TimeInterval {
        duration - (ProcessInfo.processInfo.systemUptime - started)
    }
    let system = AXMenuSystemReader(remaining: remaining)
    let application = AXUIElementCreateApplication(pid)
    let menuBar = system.element(application, kAXMenuBarAttribute)
    return readActiveAXMenus(
        menuBar: menuBar, focused: { system.element(application, kAXFocusedUIElementAttribute) }, pid: pid,
        maximumNodes: min(maximumNodes, 256), expired: { remaining() <= 0 },
        foundCandidate: { if remaining() > 0 { duration = AXMenuDiscoveryBudget.withCandidate } },
        rootWindowID: windowID,
        windowEvidence: { system.windows(pid: pid) },
        prepareForPublication: {
            // SDK：非 system-wide 对象设 0 后使用当前全局超时；不修改全局或普通 root。
            AXUIElementSetMessagingTimeout($0, 0) == .success
        },
        validateWindow: {
            // 重新取得窗口句柄，不能更改 snapshot 持有对象的 timeout。
            for window in system.array(application, kAXWindowsAttribute).prefix(32) {
                guard remaining() > 0 else { return false }
                if system.owner(window) == pid, system.prepare(window),
                   SkyLightSPI.shared.windowID(for: window) == windowID {
                    return system.frame(window) == bounds && remaining() > 0
                }
            }
            return false
        },
        reader: AXMenuReader(
            owner: system.owner,
            role: { system.value($0, kAXRoleAttribute) as? String },
            selected: { system.value($0, kAXSelectedAttribute) as? Bool == true },
            visible: { system.value($0, "AXVisible") as? Bool },
            expanded: { system.value($0, "AXExpanded") as? Bool },
            frame: system.frame,
            parent: { system.element($0, kAXParentAttribute) },
            children: system.array,
            equal: { CFEqual($0, $1) }
        )
    )
}

/// 活动菜单发现的时间预算（秒）。
enum AXMenuDiscoveryBudget {
    /// 还没发现任何菜单候选时的总预算：没有菜单的常规快照只多付这么多。
    static let discovery: TimeInterval = 0.08
    /// 发现候选后 discovery + 复核的总预算。
    static let withCandidate: TimeInterval = 0.3
    /// 单次 AX IPC 上限。
    static let perCall: TimeInterval = 0.04
}

private struct AXMenuSystemReader {
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
              let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
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
