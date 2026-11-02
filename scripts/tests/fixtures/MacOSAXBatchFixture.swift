import AppKit

final class BatchWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class Receiver: NSObject {
    var clicks = 0
    @objc func press(_ sender: NSButton) {
        clicks += 1
        sender.title = "Changed \(clicks)"
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let receiver = Receiver()
let window = BatchWindow(contentRect: NSRect(x: 80, y: 100, width: 1000, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
window.title = "OCU AX Batch Fixture"
for index in 0..<300 {
    let button = NSButton(title: "Item \(index)", target: receiver, action: #selector(Receiver.press(_:)))
    button.frame = NSRect(x: (index % 20) * 50, y: (index / 20) * 40, width: 49, height: 35)
    window.contentView!.addSubview(button)
}
window.orderFront(nil)
let state = URL(fileURLWithPath: CommandLine.arguments[1])
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    try? JSONSerialization.data(withJSONObject: ["clicks": receiver.clicks]).write(to: state, options: .atomic)
}
Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in app.terminate(nil) }
app.run()
