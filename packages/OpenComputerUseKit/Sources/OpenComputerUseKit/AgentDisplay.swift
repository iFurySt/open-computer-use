import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenComputerUseVirtualDisplayShim

public enum WindowPlacement: String, CaseIterable, Sendable {
    case keep
    case agentDisplay = "agent_display"
    case restore
}

func parseWindowPlacement(_ rawValue: String?) throws -> WindowPlacement {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? WindowPlacement.keep.rawValue

    guard let placement = WindowPlacement(rawValue: normalized) else {
        let expected = WindowPlacement.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid window_placement '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return placement
}

/// Where a parked window goes on the agent display: inset from the top-left
/// corner, clamped so at least the top-left `minVisible` points stay inside the
/// display when the window is larger than it.
func agentDisplayPlacement(windowSize: CGSize, displayBounds: CGRect, inset: CGFloat = 40, minVisible: CGFloat = 200) -> CGPoint {
    let maxX = max(displayBounds.minX, displayBounds.maxX - max(windowSize.width, minVisible))
    let maxY = max(displayBounds.minY, displayBounds.maxY - max(windowSize.height, minVisible))
    return CGPoint(
        x: min(displayBounds.minX + inset, maxX),
        y: min(displayBounds.minY + inset, maxY)
    )
}

/// The agent's own display: a virtual display (the mechanism behind Screen
/// Sharing's headless sessions) that the user never sees. A window parked on it
/// is genuinely on screen for WindowServer, so its app renders it, exposes its
/// full accessibility tree and accepts input, while the user's Space, foreground
/// app and pointer are untouched. Parking moves the window's frame (AX
/// position, no activation); the original position is restored on `restore`
/// and at process exit, and the display is removed once nothing is parked.
final class AgentDisplay: @unchecked Sendable {
    static let shared = AgentDisplay()

    static let displaySize = CGSize(width: 1920, height: 1080)
    // Upper bounds for the polls; the observed values are far lower and are
    // logged with OPEN_COMPUTER_USE_DEBUG_TIMING=1.
    static let displaySettle: TimeInterval = 3.0
    static let moveSettle: TimeInterval = 2.0
    // Fallback sleeps when the observation SPIs are unavailable.
    static let displayFallbackSettle: TimeInterval = 0.5
    static let moveFallbackSettle: TimeInterval = 1.0

    struct ParkedWindow {
        let pid: pid_t
        let element: AXUIElement
        let originalPosition: CGPoint
    }

    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var displaySpaceIDs: Set<UInt64> = []
    private var parked: [CGWindowID: ParkedWindow] = [:]
    private var exitHookInstalled = false

    var isSupported: Bool {
        ocu_virtual_display_is_supported() != 0
    }

    var displayBounds: CGRect? {
        displayID == 0 ? nil : CGDisplayBounds(displayID)
    }

    func isParked(windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked[windowID] != nil
    }

    func parkedWindowIDs(pid: pid_t) -> [CGWindowID] {
        lock.lock()
        defer { lock.unlock() }
        return parked.filter { $0.value.pid == pid }.map(\.key)
    }

    /// Move `window` onto the agent display. Returns the display bounds.
    @discardableResult
    func park(windowID: CGWindowID, pid: pid_t, window: AXUIElement) throws -> CGRect {
        lock.lock()
        defer { lock.unlock() }

        let bounds = try ensureDisplay()
        if parked[windowID] != nil {
            return bounds
        }

        guard let position = axPoint(window, kAXPositionAttribute as String) else {
            throw ComputerUseError.stateUnavailable("window_placement 'agent_display' could not read the window position")
        }
        let size = axSize(window) ?? CGSize(width: 800, height: 600)
        let target = agentDisplayPlacement(windowSize: size, displayBounds: bounds)
        let start = TimingLog.now()
        try setAXPosition(window, target)
        parked[windowID] = ParkedWindow(pid: pid, element: window, originalPosition: position)
        installExitHookIfNeeded()
        waitForWindow(windowID, toLandOn: displaySpaceIDs, or: bounds)
        TimingLog.log("agent_display.park", since: start)
        return bounds
    }

    /// Wait until the window's frame sits inside the display and, when the
    /// Space SPI is available, WindowServer also reports it on one of the
    /// display's Spaces. Space membership alone precedes the frame update.
    private func waitForWindow(_ windowID: CGWindowID, toLandOn spaceIDs: Set<UInt64>, or bounds: CGRect) {
        let spi = SkyLightSPI.shared
        let landed = waitUntil(timeout: Self.moveSettle) {
            guard let frame = Self.windowFrame(windowID),
                  bounds.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 1))
            else { return false }
            if !spaceIDs.isEmpty, let spaces = spi.spaces(forWindow: windowID) {
                return spaces.contains(where: spaceIDs.contains)
            }
            return true
        }
        if landed == nil {
            Thread.sleep(forTimeInterval: Self.moveFallbackSettle)
        }
    }

    private static func windowFrame(_ windowID: CGWindowID) -> CGRect? {
        let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? NSNumber, number.uint32Value == windowID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { continue }
            return bounds
        }
        return nil
    }

    static func isRestored(frame: CGRect, to originalPosition: CGPoint, tolerance: CGFloat = 1) -> Bool {
        abs(frame.minX - originalPosition.x) < tolerance
            && abs(frame.minY - originalPosition.y) < tolerance
    }

    /// Put a parked window back where it was.
    func restore(windowID: CGWindowID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = parked[windowID] else {
            return
        }
        let start = TimingLog.now()
        do {
            try setAXPosition(entry.element, entry.originalPosition)
        } catch {
            // A closed target no longer needs restoration. Forget it so the
            // virtual display can still be removed. Keep live failures for a
            // later retry instead of losing the original position.
            if Self.windowFrame(windowID) == nil {
                parked.removeValue(forKey: windowID)
                destroyDisplayIfIdle()
                return
            }
            throw error
        }
        let back = waitUntil(timeout: Self.moveSettle) {
            guard let frame = Self.windowFrame(windowID) else { return false }
            return Self.isRestored(frame: frame, to: entry.originalPosition)
        }
        if back == nil {
            Thread.sleep(forTimeInterval: Self.moveFallbackSettle)
            guard let frame = Self.windowFrame(windowID) else {
                parked.removeValue(forKey: windowID)
                destroyDisplayIfIdle()
                return
            }
            guard Self.isRestored(frame: frame, to: entry.originalPosition) else {
                throw ComputerUseError.stateUnavailable(
                    "window_placement 'restore' could not confirm that the window returned to its original position"
                )
            }
        }
        parked.removeValue(forKey: windowID)
        TimingLog.log("agent_display.restore", since: start)
        destroyDisplayIfIdle()
    }

    func restoreAll() {
        lock.lock()
        let windowIDs = Array(parked.keys)
        lock.unlock()
        for windowID in windowIDs {
            try? restore(windowID: windowID)
        }
    }

    /// Restore every window parked for one application. Unlike process-exit
    /// cleanup, an explicit restore reports a live failure to the caller after
    /// attempting the remaining windows.
    func restoreAll(pid: pid_t) throws {
        let windowIDs = parkedWindowIDs(pid: pid)
        var firstError: Error?
        for windowID in windowIDs {
            do {
                try restore(windowID: windowID)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    // MARK: - Display lifecycle (call with lock held)

    private func ensureDisplay() throws -> CGRect {
        try VirtualDisplayConfig.current.requireEnabled()
        if displayID != 0, let bounds = displayBounds, !bounds.isEmpty {
            return bounds
        }
        guard isSupported else {
            throw ComputerUseError.message("window_placement 'agent_display' is unavailable: CGVirtualDisplay is not present on this macOS")
        }
        let spi = SkyLightSPI.shared
        let spacesBefore = Set((spi.managedDisplaySpaces() ?? [:]).values.flatMap { $0 })
        let start = TimingLog.now()
        var newHandle: UnsafeMutableRawPointer?
        let id = ocu_virtual_display_create("Open Computer Use", UInt32(Self.displaySize.width), UInt32(Self.displaySize.height), 60, &newHandle)
        guard id != 0, let newHandle else {
            throw ComputerUseError.message("window_placement 'agent_display' could not create the agent display")
        }
        handle = newHandle
        displayID = id
        TimingLog.log("agent_display.create", since: start)

        // Ready means WindowServer reports the display's bounds and has given
        // it a Space; without the Space SPI, fall back to a fixed settle.
        var newSpaces: Set<UInt64> = []
        let ready = waitUntil(timeout: Self.displaySettle) {
            guard let bounds = self.displayBounds, !bounds.isEmpty else { return false }
            guard let displays = spi.managedDisplaySpaces() else { return true }
            newSpaces = Set(displays.values.flatMap { $0 }).subtracting(spacesBefore)
            return !newSpaces.isEmpty
        }
        if ready == nil, displayBounds?.isEmpty != false {
            destroyDisplay()
            throw ComputerUseError.message("window_placement 'agent_display' timed out waiting for the agent display")
        }
        if newSpaces.isEmpty {
            Thread.sleep(forTimeInterval: Self.displayFallbackSettle)
        }
        displaySpaceIDs = newSpaces
        TimingLog.log("agent_display.ready", since: start)
        return displayBounds ?? .zero
    }

    private func destroyDisplayIfIdle() {
        if parked.isEmpty {
            destroyDisplay()
        }
    }

    private func destroyDisplay() {
        if let handle {
            ocu_virtual_display_destroy(handle)
        }
        handle = nil
        displayID = 0
        displaySpaceIDs = []
    }

    private func installExitHookIfNeeded() {
        guard !exitHookInstalled else { return }
        exitHookInstalled = true
        atexit {
            AgentDisplay.shared.restoreAll()
        }
    }

    // MARK: - AX helpers

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func setAXPosition(_ element: AXUIElement, _ point: CGPoint) throws {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else {
            throw ComputerUseError.message("could not encode the window position")
        }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else {
            throw ComputerUseError.stateUnavailable("window_placement could not move the window (AXError \(result.rawValue))")
        }
    }
}
