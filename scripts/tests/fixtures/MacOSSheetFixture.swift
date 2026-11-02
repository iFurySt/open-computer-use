import AppKit

// Model Gecko's parent window, which omits sheets from AXChildren.
final class FilteredWindow: NSWindow {
    var hideSheets = false
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren()
        return hideSheets ? children?.filter { !($0 is NSWindow) } : children
    }
}
final class Controller: NSObject {
    let window = FilteredWindow(contentRect: NSRect(x: 150, y: 180, width: 900, height: 600),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let commandURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let directoryURL = URL(fileURLWithPath: CommandLine.arguments[3])
    var panel: NSPanel?
    var completed = 0
    var response = 0
    var lastCommand = ""
    var timer: Timer?
    override init() {
        super.init()
        window.title = "OCU Sheet Parent"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Parent-only content")
        label.frame = NSRect(x: 30, y: 40, width: 300, height: 30)
        window.contentView!.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [self] _ in tick() }
        RunLoop.main.add(timer!, forMode: .modalPanel)
    }
    @objc func cancelCustom(_ sender: Any?) {
        // Modal processing may outlast the query's read budget; the action must
        // still report success instead of retrying against a disappearing sheet.
        Thread.sleep(forTimeInterval: 0.15)
        if let panel { window.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
    }
    func tick() {
        let command = (try? String(contentsOf: commandURL, encoding: .utf8)) ?? ""
        if command != lastCommand {
            lastCommand = command
            if command.hasPrefix("open:") && panel == nil {
                let mode = command.split(separator: ":")[1]
                window.hideSheets = mode == "filtered"
                if mode == "custom" {
                    let next = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    next.isReleasedWhenClosed = false
                    let button = NSButton(title: "Cancel", target: self, action: #selector(cancelCustom(_:)))
                    button.frame = NSRect(x: 280, y: 20, width: 100, height: 32)
                    next.contentView!.addSubview(button)
                    panel = next
                    window.beginSheet(next) { [self] result in
                        completed += 1; response = result.rawValue; panel = nil
                    }
                    return
                }
                let next = NSOpenPanel()
                next.directoryURL = directoryURL
                next.canChooseDirectories = false
                next.canChooseFiles = true
                next.allowsMultipleSelection = false
                next.prompt = "Choose test file"
                next.message = "OCU sheet regression fixture"
                panel = next
                let completion: (NSApplication.ModalResponse) -> Void = { [self] result in
                    completed += 1; response = result.rawValue; panel = nil
                }
                if mode == "modal" {
                    DispatchQueue.main.async { completion(next.runModal()) }
                } else {
                    next.beginSheetModal(for: window, completionHandler: completion)
                }
            }
        }
        let target = panel ?? window
        let frame = target.frame
        let data = try! JSONSerialization.data(withJSONObject: [
            "open": panel != nil, "visible": panel?.isVisible ?? false,
            "parentIncludesPanel": panel.map { sheet in
                window.accessibilityChildren()?.contains { ($0 as? NSWindow) === sheet } ?? false
            } ?? false,
            "completed": completed, "response": response,
            "windowID": target.windowNumber, "parentID": window.windowNumber,
            "size": [frame.width, frame.height], "scale": target.backingScaleFactor])
        try? data.write(to: stateURL, options: .atomic)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in app.terminate(nil) }
app.run()
