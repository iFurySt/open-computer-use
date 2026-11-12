import AppKit
final class IdentityController: NSObject {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 440, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    let alpha = NSButton(title: "Alpha", target: nil, action: nil)
    let beta = NSButton(title: "Beta", target: nil, action: nil)
    let input = NSTextField(string: "initial")
    var pressed: [String] = []
    var applied = ""
    func publish() {
        let data = try! JSONSerialization.data(withJSONObject: ["pressed": pressed, "applied": applied, "text": input.stringValue])
        try! data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    @objc func press(_ sender: NSButton) { pressed.append(sender.title); publish() }
    func start() {
        window.title = "OCU Identity Fixture"
        for (button, y) in [(alpha, 150.0), (beta, 95.0)] {
            button.target = self; button.action = #selector(press(_:)); button.frame = NSRect(x: 30, y: y, width: 180, height: 36)
            window.contentView!.addSubview(button)
        }
        input.frame = NSRect(x: 30, y: 35, width: 300, height: 28); input.setAccessibilityIdentifier("identity-input")
        window.contentView!.addSubview(input)
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [self] _ in
            if let command = try? String(contentsOf: root.appendingPathComponent("command"), encoding: .utf8), command != applied {
                if command == "swap" { alpha.title = "Beta"; beta.title = "Alpha" }
                if command == "rename" { alpha.title = "Gamma"; beta.title = "Delta" }
                applied = command
            }
            publish()
        }
        window.makeKeyAndOrderFront(nil); publish()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = IdentityController(); controller.start(); app.run()
