import AppKit

// Also decode PNG markers, keeping the runner dependency-free.
if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--pixels" {
    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
    let points = stride(from: 3, to: CommandLine.arguments.count, by: 2).map { i -> [Int] in
        let x = min(bitmap.pixelsWide - 1, Int(Double(CommandLine.arguments[i])! * Double(bitmap.pixelsWide)))
        let y = min(bitmap.pixelsHigh - 1, Int(Double(CommandLine.arguments[i + 1])! * Double(bitmap.pixelsHigh)))
        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    print(String(data: try JSONSerialization.data(withJSONObject: points), encoding: .utf8)!)
    exit(0)
}

final class FixtureWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class MarkerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index) * 200, y: 0, width: 200, height: 400).fill()
        }
    }
}

final class InvalidFrameView: NSView {
    var mode = "normal"
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Invalid geometry probe" }
    override func accessibilityIdentifier() -> String { "invalid-geometry-probe" }
    override func accessibilityFrame() -> NSRect {
        switch mode {
        case "bad-position": return NSRect(x: CGFloat.nan, y: 100, width: 80, height: 20)
        case "bad-size": return NSRect(x: 100, y: 100, width: CGFloat.nan, height: 20)
        default: return super.accessibilityFrame()
        }
    }
}

final class Counter: NSObject {
    var left = 0
    var right = 0
    @objc func pressLeft(_ sender: Any?) { left += 1 }
    @objc func pressRight(_ sender: Any?) { right += 1 }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0].frame
let window = FixtureWindow(contentRect: NSRect(x: 120, y: screen.midY - 200, width: 600, height: 400),
                           styleMask: [.titled], backing: .buffered, defer: false)
window.title = "OCU Snapshot Geometry Fixture"
window.isReleasedWhenClosed = false
let canvas = MarkerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
window.contentView = canvas
let counter = Counter()
for (x, title, action) in [(60.0, "Left target", #selector(Counter.pressLeft(_:))),
                            (420.0, "Right target", #selector(Counter.pressRight(_:)))] {
    let button = NSButton(frame: NSRect(x: x, y: 60, width: 120, height: 40))
    button.title = title
    button.target = counter
    button.action = action
    canvas.addSubview(button)
}
let invalid = InvalidFrameView(frame: NSRect(x: 260, y: 240, width: 80, height: 20))
canvas.addSubview(invalid)
window.orderFront(nil)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var mode = "normal"
Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
    if let next = try? String(contentsOf: root.appendingPathComponent("command"), encoding: .utf8), next != mode {
        mode = next
        invalid.mode = next
        let x: CGFloat = next == "right-offscreen" ? screen.maxX - 300 : next == "left-offscreen" ? screen.minX - 300 : 120
        window.setFrameOrigin(NSPoint(x: x, y: screen.midY - 200))
        NSAccessibility.post(element: invalid, notification: .layoutChanged)
    }
    let frame = window.frame
    let data = try! JSONSerialization.data(withJSONObject: [
        "mode": mode, "leftClicks": counter.left, "rightClicks": counter.right,
        "windowSize": [frame.width, frame.height], "windowOrigin": [frame.minX, screen.maxY - frame.maxY],
        "leftPoint": [120, frame.height - 80], "rightPoint": [480, frame.height - 80],
        "markerY": frame.height - 180, "scale": window.backingScaleFactor,
    ])
    try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
}
Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in app.terminate(nil) }
app.run()
