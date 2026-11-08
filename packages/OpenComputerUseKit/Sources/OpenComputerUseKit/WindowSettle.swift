import ApplicationServices
import Foundation

/// Waiting for a window to settle the way Codex's `waitForUIToSettle` judges it: by busy signs in the window
/// (an AXBusyIndicator, an AXWebArea whose AXLoaded is false, an element whose AXElementBusy is true), with no
/// quiet period first. A quiet period is paid by every read whether or not anything moved; a window showing no
/// busy sign is read after one scan.
enum WindowSettle {
    /// Breadth first, so the toolbar and a page's top levels come first; deep enough for a web area's spinner.
    static let scanNodes = 100
    static let scanDepth = 25
    /// How long a busy window waits before it is looked at again.
    static let interval: TimeInterval = 0.05

    /// What the scan reads from one node.
    struct Signs<Element> {
        let role: String?
        let children: [Element]
        let busy: Bool?
        let loaded: Bool?
    }

    /// Whether the window under `root` shows a busy sign, breadth first to `scanNodes` nodes and `scanDepth`
    /// levels. When the walk has read every node it queued, it reads all newly queued ones in one `read` call
    /// (in order), so it visits the same nodes in the same order, with the same answer, as reading one at a time.
    static func busy<Element>(from root: Element, read: ([Element]) -> [Signs<Element>?]) -> Bool {
        var nodes: [(element: Element, depth: Int)] = [(root, 0)]
        var signs: [Signs<Element>?] = []
        var next = 0
        while next < nodes.count {
            if next == signs.count { signs += read(nodes[next...].map(\.element)) }
            let depth = nodes[next].depth
            next += 1
            guard let node = signs[next - 1] else { continue }
            if node.role == kAXBusyIndicatorRole || (node.role == "AXWebArea" && node.loaded == false) || node.busy == true {
                return true
            }
            if depth < scanDepth {
                nodes += node.children.prefix(max(0, scanNodes - nodes.count)).map { ($0, depth + 1) }
            }
        }
        return false
    }

    /// Looks at `busy` until it is false, again `interval` after each busy look, within `timeout`. Returns
    /// whether the window stopped looking busy; no look starts past the deadline. Clock and sleep are
    /// injectable for tests.
    static func wait(
        timeout: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        busy: () throws -> Bool
    ) rethrows -> Bool {
        let deadline = now() + timeout
        while try busy() {
            guard now() + interval < deadline else { return false }
            sleep(interval)
        }
        return true
    }

    /// Each element's signs, read side by side: the app answers one read while the next is on its way.
    static func readAll(_ elements: [AXUIElement]) -> [Signs<AXUIElement>?] {
        // Each slot is written by its own iteration only.
        nonisolated(unsafe) let signs = UnsafeMutableBufferPointer<Signs<AXUIElement>?>.allocate(capacity: elements.count)
        nonisolated(unsafe) let elements = elements
        signs.initialize(repeating: nil)
        defer { signs.deinitialize(); signs.deallocate() }
        DispatchQueue.concurrentPerform(iterations: elements.count) { signs[$0] = read(elements[$0]) }
        return Array(signs)
    }

    private static let attributes = [kAXRoleAttribute, kAXChildrenAttribute, "AXElementBusy", "AXLoaded"]

    private static func read(_ element: AXUIElement) -> Signs<AXUIElement>? {
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &copied) == .success,
              let values = copied as? [Any], values.count == 4 else { return nil }
        return Signs(role: values[0] as? String, children: values[1] as? [AXUIElement] ?? [],
                     busy: values[2] as? Bool, loaded: values[3] as? Bool)
    }
}
