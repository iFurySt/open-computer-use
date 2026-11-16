import AppKit
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class CursorCancellationTests: XCTestCase {
    func testResetDropsQueuedVisualWorkButAllowsNewWork() {
        _ = NSApplication.shared
        @MainActor final class Recording { var played: [Int] = [] }
        let recording = Recording()
        let submitted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            VisualCursorSupport.performOnMain { recording.played.append(1) }
            VisualCursorSupport.performOnMain { recording.played.append(2) }
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 3), .success)
        resetOpenComputerUseVisualCursor()
        let drained = expectation(description: "new work")
        Thread.detachNewThread {
            VisualCursorSupport.performOnMain { recording.played.append(3); drained.fulfill() }
        }
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(recording.played, [3])
    }

    func testInvalidBurstFloorCannotCreateNonFiniteOrZeroDurations() {
        for raw in ["nan", "inf", "-1", "0", "invalid"] {
            XCTAssertEqual(visualCursorBurstFloor(environment: ["OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR": raw]), 0.15)
        }
        XCTAssertEqual(visualCursorBurstFloor(environment: ["OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR": "1"]), 1)
        XCTAssertEqual(visualCursorBurstFloor(environment: ["OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR": "0.2"]), 0.2)
    }

    func testBackgroundResetDoesNotDiscardNextSessionWork() {
        @MainActor final class Recording { var played: [Int] = [] }
        let recording = Recording()
        let submitted = DispatchSemaphore(value: 0)
        let drained = expectation(description: "new session")
        Thread.detachNewThread {
            VisualCursorSupport.performOnMain { recording.played.append(1) }
            resetOpenComputerUseVisualCursor()
            VisualCursorSupport.performOnMain { recording.played.append(2); drained.fulfill() }
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 3), .success)
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(recording.played, [2])
    }

    func testSupersededBackgroundResetDoesNotHideNewCursor() throws {
        _ = NSApplication.shared
        guard let frame = NSScreen.main?.visibleFrame else { throw XCTSkip("requires a display") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-cursor-reset-\(UUID().uuidString).json")
        let previous = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE"]
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", file.path, 1)
        defer {
            SoftwareCursorOverlay.reset()
            if let previous { setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", previous, 1) }
            else { unsetenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE") }
            try? FileManager.default.removeItem(at: file)
        }
        let submitted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resetOpenComputerUseVisualCursor()
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 3), .success)
        SoftwareCursorOverlay.reset()
        SoftwareCursorOverlay.settle(at: CGPoint(x: frame.midX, y: frame.midY), in: nil)
        let drained = expectation(description: "old cleanup drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
        let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
        XCTAssertNotNil(state.tipPosition, "an older reset must not clear new work")
        XCTAssertNotEqual(state.phase, "hidden")
    }

    func testResetDuringGlideStopsAnimationAndLeavesItHidden() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-cursor-cancel-\(UUID().uuidString).json")
        let previous = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE"]
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", file.path, 1)
        defer {
            SoftwareCursorOverlay.reset()
            if let previous { setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", previous, 1) }
            else { unsetenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE") }
            try? FileManager.default.removeItem(at: file)
        }
        SoftwareCursorOverlay.reset()
        guard let frame = NSScreen.main?.visibleFrame else { throw XCTSkip("requires a display") }
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { resetOpenComputerUseVisualCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let start = ProcessInfo.processInfo.systemUptime
        SoftwareCursorOverlay.moveCursor(to: CGPoint(x: frame.maxX - 40, y: frame.maxY - 40), in: nil)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
        XCTAssertNil(state.tipPosition)
        XCTAssertEqual(state.phase, "hidden")
    }
}
