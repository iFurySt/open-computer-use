import AppKit
import ApplicationServices

// Lower-level real Chrome AX probe. Does not claim to test OCU session/transport.
// swiftc -parse-as-library scripts/tests/fixtures/MacOSChromeTreeProbe.swift -o /tmp/ocu-chrome-tree-probe
@main struct Probe {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
  var samples: [String: [Double]] = [:]
  for useRole in [false, true, true, false, false, true] {
   let chrome = try IsolatedChrome(page: "<!doctype html><title>OCU tree probe</title><button>OCU Fresh Page Button</button>")
   defer { chrome.stop() }
   chrome.holdFront(for: 15, untilWindow: true)
   chrome.holdFront(for: 1.5)
   let app = AXUIElementCreateApplication(chrome.pid)
   AXUIElementSetMessagingTimeout(app, 0.1)
   let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
   let start = ProcessInfo.processInfo.systemUptime
   _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
   _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
   if useRole { _ = value(app, kAXRoleAttribute) }
   var found = false
   while ProcessInfo.processInfo.systemUptime-start < 5 {
    if containsButton(app) { found = true; break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
   }
   guard found else { throw NSError(domain: "Fresh page button missing", code: 1) }
   let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
   guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else {
    throw NSError(domain: "Foreground changed during probe", code: 2)
   }
   samples[useRole ? "role" : "baseline", default: []].append(ms)
   print("\(useRole ? "role" : "baseline"): \(ms) ms")
  }
  print("RESULT \(samples)")
 }
 static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
  var result: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
  return result
 }
 static func containsButton(_ app: AXUIElement) -> Bool {
  // Do not read the application role here: that is the independent variable.
  var queue = value(app, kAXChildrenAttribute) as? [AXUIElement] ?? []
  var offset = 0
  while offset < queue.count && offset < 2000 {
   let node = queue[offset]; offset += 1
   if value(node, kAXTitleAttribute) as? String == "OCU Fresh Page Button" { return true }
   queue += value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
  }
  return false
 }
}
/// A throwaway Chrome: its own temporary profile and one page. Chrome activates itself on launch, so `holdFront` puts
/// the person's app back in front while it settles.
@MainActor
final class IsolatedChrome {
    let process = Process()
    let root: URL
    private let front = NSWorkspace.shared.frontmostApplication
    var pid: pid_t { process.processIdentifier }

    init(page html: String) throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chrome.path) else { throw NSError(domain: "Chrome missing", code: 1) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = root.appendingPathComponent("index.html")
        try html.write(to: page, atomically: false, encoding: .utf8)
        process.executableURL = chrome
        process.arguments = ["--user-data-dir=\(root.appendingPathComponent("profile").path)", "--no-first-run",
                             "--no-default-browser-check", "--disable-background-networking", "--window-size=500,400",
                             "--app=\(page.absoluteString)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func holdFront(for seconds: TimeInterval, untilWindow: Bool = false) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !(untilWindow && hasWindow) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { _ = front?.activate() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { _ = front?.activate() }
    }

    private var hasWindow: Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? NSNumber) == 0 }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }
}
