import AppKit

final class SlowClickController: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 420, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
    var slowCount = 0
    var fastCount = 0
    func publish() {
        let data = try! JSONSerialization.data(withJSONObject: ["slow": slowCount, "fast": fastCount])
        try! data.write(to: stateURL, options: .atomic)
    }
    func start() {
        window.title = "OCU Slow Click Fixture"
        for (title, y, selector) in [("Slow action", 120.0, #selector(slow)), ("Fast action", 50.0, #selector(fast))] {
            let button = NSButton(title: title, target: self, action: selector)
            button.frame = NSRect(x: 30, y: y, width: 300, height: 40)
            window.contentView!.addSubview(button)
        }
        publish()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func slow() { slowCount += 1; publish(); Thread.sleep(forTimeInterval: 2) }
    @objc func fast() { fastCount += 1; publish() }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = SlowClickController()
controller.start()
app.run()
