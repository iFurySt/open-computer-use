import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Opt-in (`OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1`): times the visual-cursor
/// phases that wrap every click (`moveCursor` before it, `pulseClick` after it)
/// when a tool thread issues them the way the service does, and checks that a
/// window capture never contains the overlay.
final class CursorAnimationLatencyLiveTests: XCTestCase {
    private static var benchEnabled: Bool {
        ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_CURSOR_BENCH"] == "1"
    }

    /// Distance from the drawn tip to `point`, read from the observation file.
    private static func tipError(from point: CGPoint) -> Double? {
        guard let url = visualCursorObservationFileURL(environment: ProcessInfo.processInfo.environment),
              let data = try? Data(contentsOf: url),
              let tip = (try? JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: data))?.tipPosition
        else { return nil }
        return hypot(tip.x - point.x, tip.y - point.y)
    }

    @MainActor
    private func withObservationFile(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-cursor-bench-\(UUID().uuidString).json")
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", file.path, 1)
        defer {
            SoftwareCursorOverlay.reset()
            unsetenv("OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE")
            try? FileManager.default.removeItem(at: file)
        }
        SoftwareCursorOverlay.reset()
        try body()
    }

    /// A tool thread issues a burst of clicks. Reports how long each click
    /// blocked it, how long each click's animation played, when the cursor
    /// caught up, and how far the tip was from the target when each pulse began.
    @MainActor
    func testBurstOfClicksDoesNotBlockTheCaller() throws {
        guard Self.benchEnabled else { throw XCTSkip("set OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1") }
        try withObservationFile {
            let clicks = 10
            let frame = try XCTUnwrap(NSScreen.main?.visibleFrame)
            let points = [CGPoint(x: frame.midX - 300, y: frame.midY - 150), CGPoint(x: frame.midX + 300, y: frame.midY + 150)]
            nonisolated(unsafe) var blocked: [Double] = []
            nonisolated(unsafe) var animation: [Double] = []
            nonisolated(unsafe) var landing: [Double] = []
            nonisolated(unsafe) var played: [Int] = []
            nonisolated(unsafe) var moveStart = 0.0
            let drained = expectation(description: "cursor caught up")

            let start = TimingLog.now()
            Thread.detachNewThread {
                for click in 0..<clicks {
                    let point = points[click % 2]
                    let callStart = TimingLog.now()
                    VisualCursorSupport.performOnMain {
                        moveStart = TimingLog.now()
                        SoftwareCursorOverlay.moveCursor(to: point, in: nil)
                    }
                    VisualCursorSupport.performOnMain {
                        landing.append(Self.tipError(from: point) ?? .nan)
                        SoftwareCursorOverlay.pulseClick(at: point, clickCount: 1, mouseButton: .left, in: nil)
                        animation.append((TimingLog.now() - moveStart) * 1000)
                        played.append(click)
                    }
                    blocked.append((TimingLog.now() - callStart) * 1000)
                }
                VisualCursorSupport.performOnMain { drained.fulfill() }
            }
            wait(for: [drained], timeout: 60)
            let caughtUpMs = (TimingLog.now() - start) * 1000

            // Past the relaxed gap the next click should play at full length again.
            RunLoop.main.run(until: Date().addingTimeInterval(2.2))
            let idleStart = TimingLog.now()
            SoftwareCursorOverlay.moveCursor(to: points[clicks % 2], in: nil)
            SoftwareCursorOverlay.pulseClick(at: points[clicks % 2], clickCount: 1, mouseButton: .left, in: nil)
            let afterIdleMs = (TimingLog.now() - idleStart) * 1000

            func list(_ values: [Double]) -> String {
                values.map { String(format: "%.1f", $0) }.joined(separator: " ")
            }
            let floor = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR"] ?? "default"
            print("BENCH cursor burst of \(clicks) clicks (burst floor \(floor))")
            print("BENCH caller blocked per click (ms): " + list(blocked) + String(format: " | mean %.2f max %.2f", blocked.reduce(0, +) / Double(clicks), blocked.max() ?? .nan))
            print("BENCH animation per click (ms): " + list(animation) + String(format: " | after 2.2 s idle %.0f", afterIdleMs))
            print(String(format: "BENCH cursor caught up after %.0f ms", caughtUpMs))
            print("BENCH landing error at pulse start (pt): " + list(landing) + String(format: " | max %.1f", landing.max() ?? .nan))

            XCTAssertEqual(played, Array(0..<clicks), "every click plays, in order")
            XCTAssertLessThan(blocked.max() ?? .infinity, 20, "the caller must not wait for the animation")
            XCTAssertLessThan(landing.max() ?? .infinity, 2, "a sped-up glide still lands on the target")
        }
    }

    /// Once a click returns before its animation ends, a screenshot taken right
    /// after it can overlap the cursor mid-glide. Window captures are per
    /// window, so the overlay panel above the target must not appear in them.
    @MainActor
    func testWindowCaptureExcludesTheCursorOverlay() throws {
        guard Self.benchEnabled else { throw XCTSkip("set OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1") }
        try withObservationFile {
            let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
            let window = NSWindow(
                contentRect: CGRect(x: screen.midX - 150, y: screen.midY - 100, width: 300, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.backgroundColor = .white
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let windowID = CGWindowID(window.windowNumber)
            func capture() throws -> Data {
                let image = try XCTUnwrap(SkyLightSPI.shared.hardwareCaptureWindow(windowID), "hardware window capture unavailable")
                return try XCTUnwrap(image.dataProvider?.data as Data?)
            }

            let clean = try capture()
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            SoftwareCursorOverlay.moveCursor(to: center, in: CursorTargetWindow(windowID: windowID, layer: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertLessThan(Self.tipError(from: center) ?? .infinity, 2, "the overlay is drawn over the window")
            XCTAssertEqual(try capture(), clean, "the overlay must not appear in a window capture")
        }
    }
}
