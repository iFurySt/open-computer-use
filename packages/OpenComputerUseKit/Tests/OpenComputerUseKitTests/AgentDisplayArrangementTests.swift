import AppKit
import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class AgentDisplayArrangementTests: XCTestCase {
    func testDoNotRestoreArrangementAfterDisplayCountOrModeChanges() {
        let original = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(agentDisplayOrigin(displaysBefore: [original], displaysNow: []))
        XCTAssertNil(agentDisplayOrigin(displaysBefore: [original], displaysNow: [CGRect(x: 1920, y: 0, width: 1280, height: 720)]))
        XCTAssertNil(agentDisplayOrigin(displaysBefore: [.null], displaysNow: [original]))
    }

    func testRestorationOnlyIncludesPreviouslyVisibleMovedWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let virtual = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let old: [CGWindowID: CGRect] = [1: CGRect(x: 50, y: 50, width: 400, height: 300),
                                       2: CGRect(x: -2000, y: 0, width: 400, height: 300),
                                       3: CGRect(x: 100, y: 100, width: 400, height: 300)]
        let new: [CGWindowID: CGRect] = [1: CGRect(x: 1500, y: 50, width: 400, height: 300),
                                       2: CGRect(x: 1500, y: 50, width: 400, height: 300),
                                       3: old[3]!, 4: CGRect(x: 1500, y: 100, width: 400, height: 300)]
        XCTAssertEqual(windowsMovedOntoAgentDisplay(virtual, userDisplays: [screen], before: old, now: new), [1: CGPoint(x: 50, y: 50)])
    }

    func testRealVirtualDisplayPreservesLayoutAndRestoresOwnedWindow() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LAYOUT_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_AGENT_DISPLAY_LAYOUT_TEST=1 for a temporary virtual display and owned window")
        }
        guard AgentDisplay.shared.isSupported, AXIsProcessTrusted() else { throw XCTSkip("Virtual display or AX unavailable") }
        _ = NSApplication.shared
        NSApplication.shared.finishLaunching()
        let screens = displayFrames()
        let main = CGMainDisplayID()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-display-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let binary = temporary.appendingPathComponent("LayoutFixture")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", root.appendingPathComponent("scripts/tests/fixtures/MacOSDisplayLayoutFixture.swift").path, "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let fixture = Process()
        fixture.executableURL = binary
        try fixture.run()
        defer {
            AgentDisplay.shared.restoreAll()
            fixture.terminate()
            fixture.waitUntilExit()
        }
        let app = AXUIElementCreateApplication(fixture.processIdentifier)
        var element: AXUIElement?
        let deadline = Date().addingTimeInterval(10)
        while element == nil && Date() < deadline {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success {
                element = (raw as? [AXUIElement])?.first { candidate in
                    var title: CFTypeRef?
                    return AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &title) == .success && title as? String == "OCU layout A"
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let target = try XCTUnwrap(element)
        let original = try position(target)
        let id = try XCTUnwrap(SkyLightSPI.shared.windowID(for: target))
        for _ in 0..<2 {
            let bounds = try AgentDisplay.shared.park(windowID: id, pid: fixture.processIdentifier, window: target)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(bounds.contains(try position(target)))
            XCTAssertEqual(displayFrames().filter { screens[$0.key] != nil }, screens)
            XCTAssertEqual(CGMainDisplayID(), main)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
            try AgentDisplay.shared.restore(windowID: id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(try position(target).x, original.x, accuracy: 1)
            XCTAssertEqual(try position(target).y, original.y, accuracy: 1)
            let until = Date().addingTimeInterval(3)
            while displayFrames().count != screens.count && Date() < until {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(displayFrames(), screens)
        }
        // Reproduce a display-owner crash with a separate process. Only our A
        // window is deliberately left on that display; B triggers the next one.
        let ownerBinary = temporary.appendingPathComponent("DisplayOwner")
        let ownerCompiler = Process()
        ownerCompiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        ownerCompiler.arguments = ["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics",
            "-I", root.appendingPathComponent("packages/OpenComputerUseVirtualDisplayShim/include").path,
            root.appendingPathComponent("scripts/tests/fixtures/MacOSAgentDisplayOwner.m").path,
            root.appendingPathComponent("packages/OpenComputerUseVirtualDisplayShim/OpenComputerUseVirtualDisplayShim.m").path,
            "-o", ownerBinary.path]
        try ownerCompiler.run(); ownerCompiler.waitUntilExit()
        XCTAssertEqual(ownerCompiler.terminationStatus, 0)
        let identifier = temporary.appendingPathComponent("display-id")
        let owner = Process(); owner.executableURL = ownerBinary; owner.arguments = [identifier.path]
        try owner.run()
        defer { if owner.isRunning { owner.terminate(); owner.waitUntilExit() } }
        let ownerDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: identifier.path) && Date() < ownerDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let abandonedID = try XCTUnwrap(UInt32(String(contentsOf: identifier, encoding: .utf8)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let abandonedBounds = CGDisplayBounds(abandonedID)
        var abandonedPoint = CGPoint(x: abandonedBounds.minX + 40, y: abandonedBounds.minY + 40)
        let abandonedValue = try XCTUnwrap(AXValueCreate(.cgPoint, &abandonedPoint))
        XCTAssertEqual(AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, abandonedValue), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(abandonedBounds.contains(try position(target)))
        kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit()
        let removeDeadline = Date().addingTimeInterval(5)
        while displayFrames().count != screens.count && Date() < removeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(displayFrames(), screens)
        var allWindows: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &allWindows), .success)
        let second = try XCTUnwrap((allWindows as? [AXUIElement])?.first { candidate in
            var title: CFTypeRef?
            return AXUIElementCopyAttributeValue(candidate, kAXTitleAttribute as CFString, &title) == .success && title as? String == "OCU layout B"
        })
        let secondID = try XCTUnwrap(SkyLightSPI.shared.windowID(for: second))
        let beforeRestart = try position(target)
        let recreatedBounds = try AgentDisplay.shared.park(windowID: secondID, pid: fixture.processIdentifier, window: second)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterRestart = try position(target)
        print("Owner crash recovery: before", beforeRestart, "after", afterRestart)
        XCTAssertFalse(recreatedBounds.contains(afterRestart), "Abandoned window returned to the invisible display")
        XCTAssertTrue(screens.values.contains { $0.contains(CGRect(origin: afterRestart, size: CGSize(width: 420, height: 300))) }, "Recovered window should fit a user display")
        try AgentDisplay.shared.restore(windowID: secondID)
        let cleanupDeadline = Date().addingTimeInterval(3)
        while displayFrames().count != screens.count && Date() < cleanupDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(displayFrames(), screens)
        print("Observed real virtual-display create/park/restore twice with \(screens.count) user display(s)")
    }

    private func position(_ element: AXUIElement) throws -> CGPoint {
        var raw: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw), .success)
        let value = try XCTUnwrap(raw)
        var point = CGPoint.zero
        XCTAssertTrue(AXValueGetValue(value as! AXValue, .cgPoint, &point))
        return point
    }

    private func displayFrames() -> [CGDirectDisplayID: CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }
}
