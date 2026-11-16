import AppKit
import XCTest
@testable import OpenComputerUseKit

/// How long the first snapshot of a fresh Chrome takes to include the page. Each round launches its own Chrome with a
/// temporary profile (never the person's browser), keeps the person's app in front while it starts, and kills it by PID.
@MainActor
final class WebTreeLiveTests: XCTestCase {
    private static let page = "<!doctype html><title>ocu-tree</title><main><h1>Tree</h1><button>Go</button></main>"

    func testFirstSnapshotOfAFreshChromeIncludesThePage() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_WEB_TREE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_WEB_TREE_LIVE_TEST=1 to launch isolated Chromes")
        }
        let rounds = Int(ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_WEB_TREE_ROUNDS"] ?? "") ?? 3
        var times: [String] = []
        for _ in 0..<rounds {
            let chrome = try IsolatedChrome(page: Self.page)
            defer { chrome.stop() }
            chrome.holdFront(for: 15, untilWindow: true)
            chrome.holdFront(for: 1.5)
            let app = try XCTUnwrap(AppDiscovery.runningApps().first { $0.pid == chrome.pid })
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = try SnapshotBuilder.build(for: app, observation: .init(includeAX: true, includeScreenshot: false))
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let text = snapshot.treeLines.joined(separator: "\n")
            times.append(String(format: "%.0f ms", elapsed) + (text.contains("button Go") ? "" : " (no page)"))
            XCTAssertTrue(text.contains("button Go"), text)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
            // Without the role read after the flags the page showed only after about 2 s of rewalks.
            if ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_WEB_TREE_BASELINE"] != "1" {
                XCTAssertLessThan(elapsed, 1000)
            }
        }
        print("BENCH first snapshot of a fresh Chrome: \(times.joined(separator: ", "))")
    }
}

/// A throwaway Chrome: its own temporary profile and one page. Chrome activates itself on launch, so `holdFront` puts
/// the person's app back in front while it settles.
@MainActor
private final class IsolatedChrome {
    let process = Process()
    let root: URL
    private let front = NSWorkspace.shared.frontmostApplication
    var pid: pid_t { process.processIdentifier }

    init(page html: String) throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chrome.path) else { throw XCTSkip("Google Chrome is not installed") }
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
