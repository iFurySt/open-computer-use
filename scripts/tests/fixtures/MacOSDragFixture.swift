import AppKit
import Foundation

// A real AppKit event receiver, not FixtureBridge's synthetic command channel.
// The command file can reset observations or close the test window; it cannot
// inject a drag, alter event counts, or manufacture a drawn path.
@MainActor
final class DragFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let stateURL: URL
    let commandURL: URL
    let foreground: Bool
    var window: NSWindow!
    var canvas: Canvas!
    var field: NSTextField!
    var timer: Timer?
    var command = ""
    var activationLosses = 0
    var keyLosses = 0
    var pointerOrigin = CGEvent(source: nil)!.location
    var maxPointerMovement: CGFloat = 0
    var observedFrontPIDs: Set<pid_t> = []
    var observations: [NSObjectProtocol] = []

    init(stateURL: URL, commandURL: URL, foreground: Bool) {
        self.stateURL = stateURL
        self.commandURL = commandURL
        self.foreground = foreground
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentSize = foreground ? NSSize(width: 640, height: 540) : NSSize(width: 460, height: 340)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 140, y: 140), size: contentSize),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = foreground ? "OCU Drag Foreground" : "OCU Drag Target"
        window.delegate = self
        window.isReleasedWhenClosed = false
        canvas = Canvas(frame: NSRect(origin: .zero, size: contentSize))
        canvas.changed = { [weak self] in self?.publish() }
        window.contentView = canvas
        field = NSTextField(string: "foreground input must not change")
        field.frame = NSRect(x: 20, y: contentSize.height - 50, width: contentSize.width - 40, height: 24)
        field.identifier = NSUserInterfaceItemIdentifier("drag-fixture-input")
        canvas.addSubview(field)
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationLosses += 1; self?.publish() }
        })
        observations.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyLosses += 1; self?.publish() }
        })
        if foreground {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(field)
        } else {
            // The target is visible but never activated by the fixture.
            window.orderFrontRegardless()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        publish()
    }

    func tick() {
        if let next = try? String(contentsOf: commandURL, encoding: .utf8), next != command {
            command = next
            if next.hasPrefix("reset:") {
                pointerOrigin = CGEvent(source: nil)!.location
                maxPointerMovement = 0
                observedFrontPIDs = []
                canvas.reset()
            }
            if next.hasPrefix("move:") { window.setFrameOrigin(NSPoint(x: 180, y: 170)) }
            if next.hasPrefix("activate:") {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if next.hasPrefix("close:") { window.close() }
        }
        let pointer = CGEvent(source: nil)!.location
        maxPointerMovement = max(maxPointerMovement, hypot(pointer.x - pointerOrigin.x, pointer.y - pointerOrigin.y))
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { observedFrontPIDs.insert(front) }
        publish()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }

    func publish() {
        guard window != nil else { return }
        let responder = window.firstResponder
        let fieldFocused = responder === field || (responder as? NSTextView)?.delegate === field
        let state: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "windowID": window.windowNumber,
            "size": [window.frame.width, window.frame.height],
            "scale": window.backingScaleFactor,
            "active": NSApp.isActive,
            "key": window.isKeyWindow,
            "visible": window.isVisible,
            "fieldFocused": fieldFocused,
            "text": field.stringValue,
            "activationLosses": activationLosses,
            "keyLosses": keyLosses,
            "events": canvas.events,
            "path": canvas.path.map { [$0.x, $0.y] },
            "renderedSegments": canvas.renderedSegments,
            "command": command,
            "pointer": [pointerOrigin.x, pointerOrigin.y],
            "maxPointerMovement": maxPointerMovement,
            "observedFrontPIDs": observedFrontPIDs.sorted(),
            "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "windowOrder": (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}

@MainActor
final class Canvas: NSView {
    var events: [[String: Any]] = []
    var path: [NSPoint] = []
    var drawing = false
    var renderedSegments = 0
    var changed: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // Keep AppKit's normal inactive-window mouse handling. No acceptsFirstMouse
    // override and no artificial active/key guard that would predetermine the test.
    override func mouseDown(with event: NSEvent) {
        record(event, kind: "down")
        drawing = true
        path = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
        changed?()
    }

    override func mouseDragged(with event: NSEvent) {
        record(event, kind: "dragged")
        if drawing { path.append(convert(event.locationInWindow, from: nil)); needsDisplay = true }
        changed?()
    }

    override func mouseUp(with event: NSEvent) {
        record(event, kind: "up")
        if drawing { path.append(convert(event.locationInWindow, from: nil)); needsDisplay = true }
        drawing = false
        changed?()
    }

    func record(_ event: NSEvent, kind: String) {
        let p = convert(event.locationInWindow, from: nil)
        events.append(["kind": kind, "point": [p.x, p.y], "windowID": event.windowNumber,
                       "active": NSApp.isActive, "key": window?.isKeyWindow ?? false])
    }

    func reset() { events = []; path = []; drawing = false; needsDisplay = true; changed?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        renderedSegments = max(0, path.count - 1)
        guard let first = path.first else { return }
        let stroke = NSBezierPath()
        stroke.move(to: first)
        for point in path.dropFirst() { stroke.line(to: point) }
        stroke.lineWidth = 4
        NSColor.black.setStroke()
        stroke.stroke()
    }
}

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("Usage: fixture state.json command.txt target|foreground") }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = DragFixture(stateURL: URL(fileURLWithPath: args[1]), commandURL: URL(fileURLWithPath: args[2]), foreground: args[3] == "foreground")
    app.delegate = delegate
    app.run()
}
