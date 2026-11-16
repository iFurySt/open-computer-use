import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
var windows: [NSWindow] = []
for (index, name) in ["OCU layout A", "OCU layout B"].enumerated() {
    let window = NSWindow(contentRect: CGRect(x: 100 + index * 500, y: 220, width: 420, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = name
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
}
application.run()
