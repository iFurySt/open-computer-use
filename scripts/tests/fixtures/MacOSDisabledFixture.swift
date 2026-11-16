import AppKit

final class DisabledController: NSObject {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 440, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    let button = NSButton(title: "Disabled target", target: nil, action: nil)
    let slider = NSSlider(value: 20, minValue: 0, maxValue: 100, target: nil, action: nil)
    var clicks = 0
    var applied = ""
    func publish() {
        let data = try! JSONSerialization.data(withJSONObject: ["clicks": clicks, "value": slider.doubleValue, "applied": applied])
        try! data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    @objc func press() { clicks += 1; publish() }
    func start() {
        window.title = "OCU Disabled Fixture"
        button.target = self; button.action = #selector(press)
        button.frame = NSRect(x: 30, y: 150, width: 250, height: 36)
        slider.frame = NSRect(x: 30, y: 70, width: 300, height: 28)
        slider.setAccessibilityIdentifier("disabled-slider")
        button.isEnabled = false; slider.isEnabled = false
        window.contentView!.addSubview(button); window.contentView!.addSubview(slider)
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [self] _ in
            if let command = try? String(contentsOf: root.appendingPathComponent("command"), encoding: .utf8), command != applied {
                button.isEnabled = command == "enable"; slider.isEnabled = command == "enable"
                applied = command
            }
            publish()
        }
        window.makeKeyAndOrderFront(nil); publish()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = DisabledController(); controller.start(); app.run()
