import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import OpenComputerUseKit

/// Opt-in live regression: a Chrome window that is already hidden (fully
/// covered) when the agent first sees it is parked on the agent display via
/// `window_placement=agent_display`; the next snapshot has the web content and
/// a screenshot, clicks and keys land, the user's Space, frontmost app and
/// pointer are untouched, and `restore` puts the window back and removes the
/// display.
@MainActor
final class AgentDisplayLiveTests: XCTestCase {
    func testHiddenChromeIsParkedOnTheAgentDisplayAndRestored() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST=1 to run the agent display live test")
        }
        setvbuf(stdout, nil, _IONBF, 0)
        guard AgentDisplay.shared.isSupported else {
            throw XCTSkip("CGVirtualDisplay is unavailable on this macOS")
        }
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            throw XCTSkip("Google Chrome is not installed at the standard path")
        }
        let originalFrontApp = NSWorkspace.shared.frontmostApplication
        defer {
            if let originalFrontApp { _ = originalFrontApp.activate(options: [.activateAllWindows]) }
        }
        let testRoot = Self.packageRoot.appendingPathComponent(".build/ocu-agent-display-\(UUID().uuidString)", isDirectory: true)
        let profileURL = testRoot.appendingPathComponent("chrome-profile", isDirectory: true)
        let pageURL = testRoot.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try Self.liveTestHTML.write(to: pageURL, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let chrome = Process()
        chrome.executableURL = chromeURL
        chrome.arguments = [
            "--user-data-dir=\(profileURL.path)", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update",
            "--window-position=200,200", "--window-size=600,420", "--app=\(pageURL.absoluteString)",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()
        defer { stop(chrome) }
        let window = try waitForWindow(pid: chrome.processIdentifier, nameContaining: "ocu-agent-", onScreenOnly: true)
        guard let runningChrome = NSRunningApplication(processIdentifier: window.pid) else { return XCTFail("Chrome not running") }
        let descriptor = RunningAppDescriptor(name: runningChrome.localizedName ?? "Google Chrome", bundleIdentifier: runningChrome.bundleIdentifier, pid: window.pid, runningApplication: runningChrome)

        // Cover Chrome before the agent ever looks at it: worst case, the page is hidden.
        let cover = try launch(executable: Self.packageRoot.appendingPathComponent(".build/debug/OpenComputerUseFixture"))
        defer { stop(cover) }
        _ = try waitForWindow(pid: cover.processIdentifier, nameContaining: "OpenComputerUseFixture", onScreenOnly: true)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let hiddenTitle = try waitForWindow(pid: window.pid, nameContaining: "ocu-agent-", onScreenOnly: false).name
        XCTAssertTrue(hiddenTitle.hasSuffix("hidden"), "Chrome must have hidden the covered page, got \(hiddenTitle)")
        let hiddenSnapshot = try SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly)
        XCTAssertFalse(hiddenSnapshot.treeLines.contains { $0.contains("sky probe paragraph") }, "hidden page must not expose web content")
        XCTAssertTrue(hiddenSnapshot.treeLines.contains { $0.hasPrefix("Note: this window is covered") })

        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mouseBefore = NSEvent.mouseLocation
        var displayCountBefore: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCountBefore)

        // Park on the agent display through the same call the tool uses.
        let windowElement = try XCTUnwrap(hiddenSnapshot.windowElement)
        let displayBounds = try AgentDisplay.shared.park(windowID: window.id, pid: window.pid, window: windowElement)
        defer { AgentDisplay.shared.restoreAll() }
        let parked = try waitForWindow(pid: window.pid, nameContaining: "ocu-agent-", onScreenOnly: false)
        print("agent display live test: display=\(displayBounds) parked=\(parked.bounds) title=\(parked.name)")
        XCTAssertTrue(displayBounds.contains(CGPoint(x: parked.bounds.minX + 1, y: parked.bounds.minY + 1)), "the window must sit on the agent display")
        let visibleTitle = try waitForWindow(pid: window.pid, nameContaining: "visible", onScreenOnly: false).name
        XCTAssertTrue(visibleTitle.hasSuffix("visible"), "Chrome must consider the parked page visible")

        let parkedSnapshot = try SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly)
        XCTAssertEqual(parkedSnapshot.targetWindowID, window.id)
        XCTAssertTrue(parkedSnapshot.treeLines.contains { $0.contains("sky probe paragraph") }, "parked snapshot must include web content")
        XCTAssertNotNil(parkedSnapshot.screenshotData)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontBefore, "parking must not change the frontmost app")
        XCTAssertEqual(NSEvent.mouseLocation, mouseBefore, "parking must not move the pointer")

        let spi = SkyLightSPI.shared
        let windowPoint = CGPoint(x: parked.bounds.width / 2, y: parked.bounds.height - 60)
        try SkyClickDispatcher.click(
            target: SkyClickTarget(
                screenPoint: CGPoint(x: parked.bounds.minX + windowPoint.x, y: parked.bounds.minY + windowPoint.y),
                windowPoint: windowPoint, windowBounds: parked.bounds, windowID: window.id, pid: window.pid),
            clickCount: 1, spi: spi)
        try SkyKeyboardDispatcher.typeText(target: SkyKeyboardTarget(windowID: window.id, pid: window.pid), text: "ok", spi: spi)
        let acted = try waitForWindow(pid: window.pid, nameContaining: "ocu-agent-ok|clicks=1|", onScreenOnly: false)
        XCTAssertTrue(acted.name.hasPrefix("ocu-agent-ok|clicks=1|"), "click and keys must reach the parked window")

        // Restore: window back where it was, display gone.
        try AgentDisplay.shared.restoreAll(pid: window.pid)
        let restored = try waitForWindow(pid: window.pid, nameContaining: "ocu-agent-", onScreenOnly: false)
        XCTAssertEqual(restored.bounds.origin, window.bounds.origin, "restore must put the window back")
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        var displayCountAfter: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCountAfter)
        XCTAssertEqual(displayCountAfter, displayCountBefore, "the agent display must be removed after restore")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontBefore)
    }

    /// Opt-in cost check: an animating page, covered, then parked, then restored. Prints Chrome's
    /// frame rate and CPU and WindowServer's CPU per phase, and click-to-pixel latency while parked.
    /// Run again with OPEN_COMPUTER_USE_AGENT_DISPLAY_REFRESH_HZ=60 to compare.
    /// docs/references/agent-display-cost.md
    func testParkedWindowCost() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_COST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_COST=1 to run the agent display cost check")
        }
        setvbuf(stdout, nil, _IONBF, 0)
        guard AgentDisplay.shared.isSupported else { throw XCTSkip("CGVirtualDisplay is unavailable on this macOS") }
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else { throw XCTSkip("Google Chrome is not installed at the standard path") }
        let seconds = Double(env["OPEN_COMPUTER_USE_AGENT_DISPLAY_COST_SECONDS"] ?? "") ?? 10
        let testRoot = Self.packageRoot.appendingPathComponent(".build/ocu-agent-display-cost-\(UUID().uuidString)", isDirectory: true)
        let pageURL = testRoot.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: testRoot.appendingPathComponent("chrome-profile"), withIntermediateDirectories: true)
        try Self.costTestHTML.write(to: pageURL, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let chrome = Process()
        chrome.executableURL = chromeURL
        chrome.arguments = [
            "--user-data-dir=\(testRoot.appendingPathComponent("chrome-profile").path)", "--no-first-run", "--no-default-browser-check",
            "--disable-background-networking", "--disable-component-update",
            "--window-position=200,200", "--window-size=600,420", "--app=\(pageURL.absoluteString)",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()
        defer { stop(chrome) }
        let window = try waitForWindow(pid: chrome.processIdentifier, nameContaining: "ocu-cost|", onScreenOnly: true)
        guard let runningChrome = NSRunningApplication(processIdentifier: window.pid) else { return XCTFail("Chrome not running") }
        let descriptor = RunningAppDescriptor(name: runningChrome.localizedName ?? "Google Chrome", bundleIdentifier: runningChrome.bundleIdentifier, pid: window.pid, runningApplication: runningChrome)
        let cover = try launch(executable: Self.packageRoot.appendingPathComponent(".build/debug/OpenComputerUseFixture"))
        defer { stop(cover) }
        _ = try waitForWindow(pid: cover.processIdentifier, nameContaining: "OpenComputerUseFixture", onScreenOnly: true)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        func title() -> String {
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.id) as? [[String: Any]] ?? []
            return info.first?[kCGWindowName as String] as? String ?? ""
        }
        func counter(_ key: String) -> Int {
            let text = title()
            guard let range = text.range(of: "|\(key)=") else { return -1 }
            return Int(text[range.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        // CPU seconds of WindowServer and of Chrome's process tree (ps TIME, 10 ms resolution).
        func cpu() -> (windowServer: Double, chrome: Double) {
            let pipe = Pipe(), ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "pid=,ppid=,time=,comm="]
            ps.standardOutput = pipe
            try? ps.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            ps.waitUntilExit()
            var windowServer = 0.0, chromeTotal = 0.0
            for line in output.split(separator: "\n") {
                let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard columns.count == 4 else { continue }
                let time = columns[2].split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
                if columns[3].hasSuffix("/WindowServer") { windowServer = time }
                if Int32(columns[0]) == window.pid || Int32(columns[1]) == window.pid { chromeTotal += time }
            }
            return (windowServer, chromeTotal)
        }
        func phase(_ name: String) -> Double {
            let (cpu0, frames0, t0) = (cpu(), counter("f"), ProcessInfo.processInfo.systemUptime)
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            let (cpu1, frames1, elapsed) = (cpu(), counter("f"), ProcessInfo.processInfo.systemUptime - t0)
            let fps = Double(frames1 - frames0) / elapsed
            print(String(format: "agent display cost: %@ refresh=%.0fHz chrome_fps=%.1f chrome_cpu=%.1f%% windowserver_cpu=%.1f%%",
                         name, AgentDisplay.refreshRate, fps, (cpu1.chrome - cpu0.chrome) / elapsed * 100, (cpu1.windowServer - cpu0.windowServer) / elapsed * 100))
            return fps
        }

        XCTAssertEqual(phase("covered"), 0, accuracy: 0.5, "a covered page draws nothing")

        let windowElement = try XCTUnwrap(try SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly).windowElement)
        try AgentDisplay.shared.park(windowID: window.id, pid: window.pid, window: windowElement)
        defer { AgentDisplay.shared.restoreAll() }
        let parked = try waitForWindow(pid: window.pid, nameContaining: "|visible", onScreenOnly: false)
        let parkedFPS = phase("parked")
        XCTAssertGreaterThan(parkedFPS, 0)
        XCTAssertLessThan(parkedFPS, AgentDisplay.refreshRate + 2, "a parked page draws at the agent display's rate")

        // Click-to-pixel: each click flips the page colour; time until a capture shows it.
        let spi = SkyLightSPI.shared
        let windowPoint = CGPoint(x: parked.bounds.width / 2, y: parked.bounds.height - 60)
        let target = SkyClickTarget(screenPoint: CGPoint(x: parked.bounds.minX + windowPoint.x, y: parked.bounds.minY + windowPoint.y), windowPoint: windowPoint, windowBounds: parked.bounds, windowID: window.id, pid: window.pid)
        var latencies: [Double] = []
        for click in 1...5 {
            let start = ProcessInfo.processInfo.systemUptime
            try SkyClickDispatcher.click(target: target, clickCount: 1, spi: spi)
            while ProcessInfo.processInfo.systemUptime - start < 3 {
                if let image = spi.hardwareCaptureWindow(window.id), Self.isGreen(image, at: CGPoint(x: parked.bounds.width - 8, y: parked.bounds.height / 2), windowWidth: parked.bounds.width) == (click % 2 == 1) {
                    latencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    break
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        latencies.sort()
        print("agent display cost: click_to_pixel_ms=\(latencies.map { Int($0) }) clicks_seen=\(counter("c"))")
        XCTAssertEqual(latencies.count, 5, "every click must show in a capture")
        XCTAssertEqual(counter("c"), 5)
        let parkedSnapshot = try SnapshotBuilder.build(for: descriptor, recoveryPolicy: .readOnly)
        XCTAssertTrue(parkedSnapshot.treeLines.contains { $0.contains("cost probe paragraph") }, "parked snapshot must include web content")

        try AgentDisplay.shared.restoreAll(pid: window.pid)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(phase("restored"), 0, accuracy: 0.5, "a restored, covered page must stop drawing")
    }

    private static func isGreen(_ image: CGImage, at point: CGPoint, windowWidth: CGFloat) -> Bool {
        let scale = CGFloat(image.width) / windowWidth
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let crop = image.cropping(to: CGRect(x: floor(point.x * scale), y: floor(point.y * scale), width: 1, height: 1)),
              let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[1] > 0x90
    }

    private struct WindowRecord { let id: CGWindowID; let pid: pid_t; let bounds: CGRect; let name: String }

    private func waitForWindow(pid: pid_t, nameContaining marker: String, onScreenOnly: Bool) throws -> WindowRecord {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
            let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
            for info in raw {
                guard let number = info[kCGWindowNumber as String] as? NSNumber,
                      let owner = info[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid,
                      let name = info[kCGWindowName as String] as? String, name.contains(marker),
                      let bounds = CGRect(dictionaryRepresentation: (info[kCGWindowBounds as String] as? NSDictionary) ?? [:]), bounds.width > 0
                else { continue }
                return WindowRecord(id: number.uint32Value, pid: pid, bounds: bounds, name: name)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw ComputerUseError.message("Timed out waiting for window title containing \(marker)")
    }

    private func launch(executable: URL) throws -> Process {
        let process = Process(); process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }

    private func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private static let liveTestHTML = #"""
    <!doctype html><meta charset="utf-8"><title>ocu-agent-ready</title>
    <style>html,body{margin:0;height:100%} input{width:90%;font:22px system-ui;margin:20px} button{position:absolute;left:0;right:0;bottom:0;height:120px;font:22px system-ui;background:#5b8def;color:#fff;border:0}</style>
    <p>sky probe paragraph</p><input id="t" autofocus placeholder="sky probe"><button id="b">click probe</button>
    <script>
      let clicks = 0; const input = document.querySelector('#t');
      const update = () => { document.title = `ocu-agent-${input.value}|clicks=${clicks}|${document.visibilityState}`; };
      document.querySelector('#b').addEventListener('click', () => { clicks += 1; update(); });
      input.addEventListener('input', update); document.addEventListener('visibilitychange', update); update();
    </script>
    """#

    /// A box turned every animation frame (the frame count goes into the title) and a button
    /// that flips the page between blue and green.
    private static let costTestHTML = #"""
    <!doctype html><meta charset="utf-8"><title>ocu-cost|f=0|c=0|</title>
    <style>html,body{margin:0;height:100%;background:#204080} p{color:#fff;margin:8px} #spin{position:absolute;left:20px;top:90px;width:100px;height:100px;background:#f80} button{position:absolute;left:0;right:0;bottom:0;height:110px;font:22px system-ui;background:#888;color:#fff;border:0}</style>
    <p>cost probe paragraph</p><div id="spin"></div><button id="b">click probe</button>
    <script>
      let frames = 0, clicks = 0; const spin = document.querySelector('#spin');
      const tick = (ts) => { frames++; spin.style.transform = `rotate(${(ts / 5) % 360}deg)`; requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
      const update = () => { document.title = `ocu-cost|f=${frames}|c=${clicks}|${document.visibilityState}`; };
      setInterval(update, 250);
      document.querySelector('#b').addEventListener('click', () => { clicks++; document.body.style.background = clicks % 2 ? '#20a040' : '#204080'; update(); });
      document.addEventListener('visibilitychange', update); update();
    </script>
    """#

    private static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()
}
