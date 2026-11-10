import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct BackgroundDragTarget {
    let start: CGPoint
    let end: CGPoint
    let windowBounds: CGRect
    let windowID: CGWindowID
    let pid: pid_t

    func validateGeometry() throws {
        let b = windowBounds
        guard windowID != 0, pid > 0,
              [start.x, start.y, end.x, end.y, b.origin.x, b.origin.y, b.width, b.height, b.maxX, b.maxY].allSatisfy(\.isFinite),
              b.width > 0, b.height > 0,
              b.contains(start), b.contains(end) else {
            throw ComputerUseError.invalidArguments("drag requires finite coordinates inside the observed target window")
        }
    }
}

/// Check the actual window, not another window selected by title or PID. A move
/// invalidates screenshot coordinates: fail instead of dragging at stale points.
func validateBackgroundDragWindow(_ target: BackgroundDragTarget, windowInfo: [[String: Any]]) throws {
    guard let info = windowInfo.first(where: {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID
            && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid
    }), let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
       let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else {
        throw ComputerUseError.stateUnavailable("drag target window disappeared or changed owner; run get_app_state again")
    }
    guard bounds == target.windowBounds else {
        throw ComputerUseError.stateUnavailable("drag target window moved: expected \(target.windowBounds), found \(bounds); run get_app_state again")
    }
}

/// A small I/O seam for failure tests. Production still uses the existing SPI
/// bridge; no fixture command, global-pointer fallback, or second delivery route.
struct BackgroundDragIO {
    let capability: SkyLightSPICapability
    var validateWindow: (BackgroundDragTarget) throws -> Void
    var needsFocus: (pid_t) throws -> Bool
    var beginFocus: (BackgroundDragTarget) throws -> SkyLightSyntheticFocusContext
    var makeKey: (SkyLightSyntheticFocusContext) throws -> Void
    var endFocus: (SkyLightSyntheticFocusContext) throws -> Void
    var setWindowLocation: (CGEvent, CGPoint) throws -> Void
    var post: (CGEvent, pid_t) -> Void
    var release: (CGEvent, BackgroundDragTarget) -> Void
    var pause: (TimeInterval) -> Void

    static func system(spi: SkyLightSPI = .shared) -> BackgroundDragIO {
        func windows() -> [[String: Any]] {
            CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        }
        return BackgroundDragIO(
            capability: spi.dragCapability,
            validateWindow: { target in
                guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated, !app.isHidden else {
                    throw ComputerUseError.stateUnavailable("drag target app is unavailable or hidden; run get_app_state again")
                }
                try validateBackgroundDragWindow(target, windowInfo: windows())
            },
            needsFocus: { pid in
                // NSWorkspace's frontmostApplication can be stale in a long-lived
                // CLI/MCP process without a pumping AppKit run loop. Read the
                // current system-wide focused app synchronously instead.
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value)
                guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    throw ComputerUseError.stateUnavailable("drag cannot determine the current foreground application")
                }
                var frontPID: pid_t = 0
                guard AXUIElementGetPid(value as! AXUIElement, &frontPID) == .success, frontPID > 0 else {
                    throw ComputerUseError.stateUnavailable("drag cannot determine the current foreground PID")
                }
                return frontPID != pid
            },
            beginFocus: { try spi.beginSyntheticTargetFocus(targetPID: $0.pid, targetWindowID: $0.windowID) },
            makeKey: { try spi.makeSyntheticTargetWindowKey($0) },
            endFocus: { try spi.endSyntheticTargetFocus($0) },
            setWindowLocation: { try spi.setWindowLocation($0, point: $1) },
            post: { $0.postToPid($1) },
            release: { event, target in
                // Release is cleanup, not a new action. Do not recheck a revoked
                // session lease, but never post to an unrelated/reused window.
                if skyKeyWindowMatchesTarget(windowInfo: windows(), windowID: target.windowID, pid: target.pid) {
                    event.postToPid(target.pid)
                }
            },
            pause: { Thread.sleep(forTimeInterval: $0) }
        )
    }
}

/// Normal `drag` background delivery. AppKit needs both a routable NSWindow and
/// its synthetic key state; a plain PID event has neither. Keep one public PID
/// post per event: click's out-of-window primer / double-post recipe is not a
/// drag recipe and can create extra presses or move selected annotations.
enum BackgroundDragDispatcher {
    private static let dispatchLock = NSLock()
    private static let windowNumberField = CGEventField(rawValue: 51)!
    private static let eventDelay: TimeInterval = 0.03

    static func drag(
        target: BackgroundDragTarget,
        io: BackgroundDragIO = .system(),
        validateSession: () throws -> Void = { try requireUsableComputerUseSession() }
    ) throws {
        try validateSession()
        try target.validateGeometry()
        guard io.capability.isAvailable else {
            throw ComputerUseError.message("background drag is unavailable: \(io.capability.unavailableReason)")
        }
        dispatchLock.lock()
        defer { dispatchLock.unlock() }
        try io.validateWindow(target)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ComputerUseError.message("Failed to create targeted drag event source")
        }
        // Allocate and stamp every event (including release at every possible
        // stopping point) before taking focus or pressing. Cleanup cannot fail
        // because a later allocation or private stamping call failed.
        func prepare(_ type: CGEventType, at point: CGPoint) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw ComputerUseError.message("Failed to prepare background drag event")
            }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
            event.setIntegerValueField(windowNumberField, value: Int64(target.windowID))
            try io.setWindowLocation(event, CGPoint(x: point.x - target.windowBounds.minX, y: point.y - target.windowBounds.minY))
            return event
        }
        let move = try prepare(.mouseMoved, at: target.start)
        let down = try prepare(.leftMouseDown, at: target.start)
        var release = try prepare(.leftMouseUp, at: target.start)
        let steps = try (1...10).map { step -> (drag: CGEvent, up: CGEvent) in
            let t = CGFloat(step) / 10
            let point = CGPoint(x: target.start.x + (target.end.x - target.start.x) * t,
                                y: target.start.y + (target.end.y - target.start.y) * t)
            return (try prepare(.leftMouseDragged, at: point), try prepare(.leftMouseUp, at: point))
        }
        func send(_ event: CGEvent) throws {
            try validateSession()
            try io.validateWindow(target)
            // Events were prepared earlier; AppKit must see delivery time, not
            // allocation time. The entire sequence remains process-addressed.
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            io.post(event, target.pid)
        }

        // If the user genuinely activates the target during a gesture, it now
        // owns real foreground focus. Do not synthetically deactivate it.
        func endFocus(_ context: SkyLightSyntheticFocusContext) throws {
            if try io.needsFocus(target.pid) { try io.endFocus(context) }
        }
        var focus: SkyLightSyntheticFocusContext?
        do {
            if try io.needsFocus(target.pid) {
                try validateSession()
                let context = try io.beginFocus(target)
                focus = context
                try validateSession()
                try io.makeKey(context)
                io.pause(0.01)
            }
            try send(move)
            io.pause(eventDelay)
            try InputSimulation.withPressedMouseButton(press: {
                try send(down)
            }, release: {
                release.timestamp = DispatchTime.now().uptimeNanoseconds
                io.release(release, target)
                io.pause(eventDelay)
            }) {
                io.pause(eventDelay)
                for step in steps {
                    try send(step.drag)
                    release = step.up
                    io.pause(eventDelay)
                }
            }
        } catch {
            if let focus {
                do { try endFocus(focus) }
                catch let cleanupError {
                    throw ComputerUseError.message("\(error); background drag focus cleanup also failed: \(cleanupError)")
                }
            }
            throw error
        }
        if let focus { try endFocus(focus) }
    }
}
