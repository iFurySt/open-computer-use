import AppKit
import Foundation
import OpenComputerUseKit

private final class ShieldWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // AppKit may constrain ordinary windows to the menu/Dock visible frame
    // after finishLaunching. A privacy surface must cover the full display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Shared visual surface for both the isolated preview and guarded rehearsal.
@MainActor
final class DisplayShieldSurface {
    private var windows: [CGDirectDisplayID: ShieldWindow] = [:]
    private var appearances: [CGDirectDisplayID: ShieldAppearance] = [:]
    private var topology = ""
    var count: Int { windows.count }

    func updateMessage(_ message: String) {
        for (id, appearance) in appearances {
            appearance.updateMessage(message)
            windows[id]?.displayIfNeeded()
        }
    }

    /// Only after root drain, an observed original-session lock and actual
    /// hardware takeover. Keep opaque coverage while loginwindow takes input.
    func allowLocalLoginInput() {
        for window in windows.values { window.ignoresMouseEvents = true }
    }

    func close() {
        for window in windows.values { window.close() }
        windows.removeAll()
        appearances.removeAll()
    }

    private func screenIDs() -> [(CGDirectDisplayID, NSScreen)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen)
        }
    }

    func displayTopology() -> String {
        screenIDs().sorted { $0.0 < $1.0 }.map { id, screen in
            "\(id):\(NSStringFromRect(screen.frame)):\(screen.backingScaleFactor)"
        }.joined(separator: "|")
    }

    func coverDisplays(message: String, levelOffset: Int = 0) throws {
        let screens = screenIDs()
        guard !screens.isEmpty else { throw GuardianError.message("No display available") }
        topology = displayTopology()
        for (id, screen) in screens {
            // The screen initializer takes screen-local coordinates. setFrame
            // below takes global Cocoa coordinates and can correct a misplaced
            // initial window, but creation should not rely on that correction.
            let frame = LockedUseShieldCoverage.surfaceFrame(for: screen.frame)
            let local = LockedUseShieldCoverage.screenLocalRect(frame, screenOrigin: screen.frame.origin)
            let window = ShieldWindow(contentRect: local, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            window.animationBehavior = .none
            window.hidesOnDeactivate = false
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = true
            window.setFrame(frame, display: true)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1 + levelOffset)
            // Default user windows disappear at loginwindow. Both protection
            // surfaces must remain onscreen across the lock/unlock transition.
            window.canBecomeVisibleWithoutLogin = true
            window.canHide = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.backgroundColor = .black
            window.isOpaque = true
            window.alphaValue = 1
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.sharingType = .none
            window.isReleasedWhenClosed = false
            let appearance = ShieldAppearance(frame: NSRect(origin: .zero, size: frame.size), screen: screen, message: message)
            window.contentView = appearance
            window.orderFrontRegardless()
            window.displayIfNeeded()
            windows[id] = window
            appearances[id] = appearance
        }
    }

    /// WindowServer evidence, not just `isVisible`. Other secure/system overlays
    /// and hotplug races still require live validation; this is not a proof that
    /// ordinary windows provide an OS-enforced privacy barrier.
    func coverageHealthy() -> Bool { coverageFailure() == nil }

    func coverageFailure() -> String? {
        guard displayTopology() == topology else { return "topologyChanged" }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return "activeDisplayCountUnavailable" }
        var active = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &active, &count) == .success else { return "activeDisplayListUnavailable" }
        for id in active.prefix(Int(count)) {
            let mirrored = CGDisplayMirrorsDisplay(id)
            guard windows[id] != nil || (mirrored != kCGNullDirectDisplay && windows[mirrored] != nil) else { return "activeDisplayUncovered" }
        }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "windowListUnavailable" }
        for (id, window) in windows {
            guard window.isVisible else { return "shieldNotVisible" }
            guard let info = infos.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }) else { return "shieldNotInWindowServer" }
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() else { return "shieldOwnerMismatch" }
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 1 else { return "shieldAlphaMismatch" }
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == window.level.rawValue else { return "shieldLayerMismatch" }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return "shieldBoundsUnavailable" }
            guard LockedUseShieldCoverage.covers(rect, display: CGDisplayBounds(id)) else { return "shieldBoundsMismatch expected=\(NSStringFromRect(CGDisplayBounds(id))) actual=\(NSStringFromRect(rect))" }
        }
        return nil
    }

}
