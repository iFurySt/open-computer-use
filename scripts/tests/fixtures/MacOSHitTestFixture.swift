import AppKit

final class HitTestWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class TargetView: NSView {
    var clicks = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityLabel() -> String? { "Hit target row" }
    override func mouseDown(with event: NSEvent) { clicks += 1 }

}
final class Counter: NSObject {
    var clicks = 0
    @objc func press(_ sender: Any?) { clicks += 1 }
}
final class CloseObserver: NSObject, NSWindowDelegate {
    var attempts = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { attempts += 1; return false }
}
let closeObserver = CloseObserver()
let guarded = CommandLine.arguments.contains("--descendant-guards")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = HitTestWindow(contentRect: NSRect(x: 120, y: 180, width: 600, height: 400),
    styleMask: guarded ? [.titled, .closable] : [.titled], backing: .buffered, defer: false)
window.title = "OCU Hit Test Fixture"
window.isReleasedWhenClosed = false
window.delegate = closeObserver
let target = TargetView(frame: NSRect(x: 280, y: 150, width: 180, height: 50))
let counter = Counter()
// Half the target's window-relative coordinates: the old Retina conversion hits this button.
let decoy = NSButton(frame: NSRect(x: 140, y: 275, width: 110, height: 50))
decoy.title = "Wrong target"
decoy.target = counter
decoy.action = #selector(Counter.press(_:))
window.contentView!.addSubview(decoy)
window.contentView!.addSubview(target)
window.orderFront(nil)
let stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
    let screenRect = window.convertToScreen(target.frame)
    let top = NSScreen.screens[0].frame.maxY
    let frame = window.frame
    let buttonRect = window.convertToScreen(decoy.frame)
    let data = try! JSONSerialization.data(withJSONObject: ["targetClicks": target.clicks, "closeAttempts": closeObserver.attempts,
        "wrongClicks": counter.clicks, "scale": window.backingScaleFactor,
        "point": [screenRect.midX - frame.minX, frame.maxY - screenRect.midY],
        "screenPoint": [screenRect.midX, top - screenRect.midY],
        "buttonPoint": [buttonRect.midX - frame.minX, frame.maxY - buttonRect.midY],
        "buttonScreenPoint": [buttonRect.midX, top - buttonRect.midY],
        "windowSize": [frame.width, frame.height],
        "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
        "pointer": [NSEvent.mouseLocation.x, top - NSEvent.mouseLocation.y]])
    try? data.write(to: stateURL, options: .atomic)
}
Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in app.terminate(nil) }
app.run()
