import AppKit
import ApplicationServices
import QuartzCore

/// Discovers only container structure; app rows and cells are never traversed.
enum PermissionListAnchorSearch {
    struct Match<Node> {
        let container: Node
        let buttons: [Node]
        let viewport: Node?
    }

    static func first<Node>(
        in root: Node,
        role: (Node) -> String?,
        children: (Node) -> [Node],
        shouldContinue: () -> Bool = { true }
    ) -> Match<Node>? {
        var stack: [(Node, Node?, Int)] = [(root, nil, 0)]
        var visited = 0
        let containers: Set<String> = [kAXWindowRole, kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole]
        while !stack.isEmpty, visited < 64, shouldContinue() {
            let (node, viewport, depth) = stack.removeLast()
            visited += 1
            guard let nodeRole = role(node), containers.contains(nodeRole), depth < 10 else { continue }
            let descendants = children(node)
            guard descendants.count <= 64 else { continue }
            var roles: [String?] = []
            for child in descendants {
                guard shouldContinue() else { return nil }
                roles.append(role(child))
            }
            let buttons = zip(descendants, roles).compactMap { $1 == kAXButtonRole ? $0 : nil }
            let hasList = roles.contains { [kAXScrollAreaRole, kAXListRole, kAXTableRole].contains($0 ?? "") }
            if nodeRole == kAXGroupRole, hasList, buttons.count == 2 {
                // Keep document order: the first list is screen recording, even
                // when its controls have scrolled out of the visible viewport.
                return Match(container: node, buttons: buttons, viewport: viewport)
            }
            let childViewport = nodeRole == kAXScrollAreaRole ? node : viewport
            for (child, childRole) in zip(descendants, roles).reversed() where containers.contains(childRole ?? "") {
                stack.append((child, childViewport, depth + 1))
            }
        }
        return nil
    }

    static func visibleFrame(container: CGRect, buttons: [CGRect], viewport: CGRect) -> CGRect? {
        guard container.width >= 300, container.height > 20, buttons.count == 2,
              buttons.allSatisfy({ !$0.isEmpty && container.insetBy(dx: -2, dy: -2).contains($0) }),
              abs(buttons[0].midY - buttons[1].midY) < 5,
              abs(buttons[0].midX - buttons[1].midX) > 10,
              buttons.allSatisfy({ $0.width < 45 && $0.height < 45 }) else { return nil }
        let controls = buttons[0].union(buttons[1])
        // SwiftUI can expose the full offscreen list height while pinning its
        // controls to the viewport's bottom. Use the visible edge only when the
        // actual buttons are at that edge, never a lower list's buttons.
        let bottom = min(container.maxY, viewport.maxY)
        let top = max(container.minY, viewport.minY)
        guard bottom > top, controls.minY >= viewport.minY - 2, controls.maxY <= viewport.maxY + 2,
              bottom >= controls.maxY - 2, bottom - controls.maxY <= 24 else { return nil }
        return CGRect(x: container.minX, y: top, width: container.width, height: bottom - top)
    }

    static func appKitRect(fromQuartz rect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Keeps Accessibility IPC off the AppKit thread and reuses the controls themselves.
actor PermissionSettingsAXReader {
    struct Observation: Sendable {
        let frame: CGRect?
        let windowBounds: CGRect
    }

    private var windowNumber: Int?
    private var match: PermissionListAnchorSearch.Match<AXUIElement>?
    private var lastDiscovery: CFTimeInterval = -.infinity
    private var windowElement: AXUIElement?
    private var windowTitle: String?

    func read(pid: pid_t, windowNumber: Int, windowBounds: CGRect) -> Observation? {
        if self.windowNumber != windowNumber {
            self.windowNumber = windowNumber
            match = nil
            lastDiscovery = -.infinity
            windowElement = nil
            windowTitle = nil
        }
        if let windowElement, value(windowElement, kAXTitleAttribute) as? String != windowTitle {
            match = nil
            lastDiscovery = -.infinity
            windowTitle = value(windowElement, kAXTitleAttribute) as? String
        }
        if let match, let frame = geometry(of: match, windowBounds: windowBounds) { return frame }
        match = nil
        let now = CACurrentMediaTime()
        guard now - lastDiscovery >= 1 else { return nil }
        lastDiscovery = now
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: {
                  guard let rect = frame(of: $0) else { return false }
                  return abs(rect.minX - windowBounds.minX) < 3 && abs(rect.minY - windowBounds.minY) < 3
                      && abs(rect.width - windowBounds.width) < 3 && abs(rect.height - windowBounds.height) < 3
              }) else { return nil }
        windowElement = window
        windowTitle = value(window, kAXTitleAttribute) as? String
        match = PermissionListAnchorSearch.first(
            in: window,
            role: { value($0, kAXRoleAttribute) as? String },
            children: { node in
                var count = 0
                guard AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) == .success,
                      count <= 64 else { return [] }
                return value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            },
            shouldContinue: { CACurrentMediaTime() - now < 0.8 }
        )
        return match.flatMap { geometry(of: $0, windowBounds: windowBounds) }
    }

    private func geometry(of match: PermissionListAnchorSearch.Match<AXUIElement>, windowBounds: CGRect) -> Observation? {
        guard let container = frame(of: match.container),
              let first = frame(of: match.buttons[0]), let second = frame(of: match.buttons[1]) else { return nil }
        let currentWindow = windowElement.flatMap { frame(of: $0) } ?? windowBounds
        let viewport = match.viewport.flatMap { frame(of: $0) }?.intersection(currentWindow) ?? currentWindow
        let visible = PermissionListAnchorSearch.visibleFrame(container: container, buttons: [first, second], viewport: viewport)
        return Observation(frame: visible, windowBounds: currentWindow)
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

@MainActor
final class PermissionSettingsWindowReader {
    private let axReader = PermissionSettingsAXReader()
    private var windowNumber: Int?
    private var windowSize = CGSize.zero
    private var relativeListFrame: CGRect?
    private var lastRead: CFTimeInterval = -.infinity
    private var reading = false
    private var generation = 0

    func context(requireFrontmost: Bool = true) -> PermissionAccessoryPanelController.SystemSettingsWindowContext? {
        guard !requireFrontmost || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences",
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }),
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let candidates: [(CGRect, Int)] = windows.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return (bounds, number)
        }
        guard let (quartzBounds, number) = candidates.max(by: { $0.0.width * $0.0.height < $1.0.width * $1.0.height }) else { return nil }
        let bounds = PermissionListAnchorSearch.appKitRect(fromQuartz: quartzBounds, primaryScreenTop: top)
        if windowNumber != number || windowSize != bounds.size {
            windowNumber = number
            windowSize = bounds.size
            relativeListFrame = nil
            lastRead = -.infinity
            generation += 1
        }
        if !AXIsProcessTrusted() {
            relativeListFrame = nil
        } else if !reading, CACurrentMediaTime() - lastRead >= 0.4 {
            reading = true
            lastRead = CACurrentMediaTime()
            let requestGeneration = generation
            let pid = app.processIdentifier
            Task { [weak self, axReader] in
                let observation = await axReader.read(pid: pid, windowNumber: number, windowBounds: quartzBounds)
                guard let self else { return }
                reading = false
                guard generation == requestGeneration else { return }
                relativeListFrame = observation.flatMap { observation in
                    guard let frame = observation.frame else { return nil }
                    let reference = PermissionListAnchorSearch.appKitRect(fromQuartz: observation.windowBounds, primaryScreenTop: top)
                    return PermissionListAnchorSearch.appKitRect(fromQuartz: frame, primaryScreenTop: top)
                        .offsetBy(dx: -reference.minX, dy: -reference.minY)
                }
            }
        }
        // Window movement does not require another AX scan or wait for its IPC.
        return .init(bounds: bounds, windowNumber: number,
                     permissionListFrame: relativeListFrame?.offsetBy(dx: bounds.minX, dy: bounds.minY))
    }
}
