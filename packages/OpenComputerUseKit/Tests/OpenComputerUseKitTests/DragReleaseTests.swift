import AppKit
import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

/// A press is always followed by its release, even when the session check fails partway (a Locked Use lease ending,
/// the Mac locking). The events go to this test process only and are read back from its own event queue.
@MainActor
final class DragReleaseTests: XCTestCase {
    private final class Countdown: @unchecked Sendable {
        var calls = 0
        let failingCall: Int
        init(failingCall: Int) { self.failingCall = failingCall }
        func check() throws {
            calls += 1
            if calls == failingCall { throw ComputerUseError.stateUnavailable("lease ended") }
        }
    }

    func testADragThatFailsPartwayReleasesTheButton() throws {
        try startReading()
        // Checks: move 1, press 2, first dragged step 3.
        let countdown = Countdown(failingCall: 3)
        XCTAssertThrowsError(try LockedUseActionScope.withValidator({ try countdown.check() }) {
            try InputSimulation.dragTargeted(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 400, y: 300), pid: getpid())
        })
        XCTAssertEqual(postedEvents(), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    func testAClickWhoseCheckFailsAfterThePressStillReleases() throws {
        try startReading()
        // Checks: move 1, press 2; the release is never refused.
        let countdown = Countdown(failingCall: 3)
        XCTAssertNoThrow(try LockedUseActionScope.withValidator({ try countdown.check() }) {
            try InputSimulation.clickTargeted(at: CGPoint(x: 300, y: 300), button: .left, clickCount: 1, pid: getpid())
        })
        XCTAssertEqual(postedEvents(), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    private func startReading() throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("Posting events needs the Accessibility permission") }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        _ = postedEvents()
    }

    private func postedEvents() -> [NSEvent.EventType] {
        var types: [NSEvent.EventType] = []
        let until = Date().addingTimeInterval(0.3)
        while let event = NSApp.nextEvent(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp], until: until, inMode: .default, dequeue: true) {
            types.append(event.type)
        }
        return types
    }
}
