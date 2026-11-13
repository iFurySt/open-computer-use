import AppKit
import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

/// Element frames are window-relative, so a cursor point derived from a
/// snapshot stops being valid the moment the window moves. These numbers are
/// the ones the bug was reproduced with: the same window on the built-in
/// display (`x = -1400`) and on the main display (`x = 600`).
final class CursorWindowAnchorTests: XCTestCase {
    private let builtInDisplayFrame = CGRect(x: -1400, y: 200, width: 500, height: 400)
    private let mainDisplayFrame = CGRect(x: 600, y: 200, width: 500, height: 400)

    private func anchor() -> CursorRestingAnchor {
        CursorRestingAnchor(
            windowID: 4242,
            layer: 0,
            windowLocalPoint: CGPoint(x: 250, y: 200),
            windowBounds: builtInDisplayFrame
        )
    }

    func testAnchorStaysPutWhileTheWindowDoesNotMove() {
        let point = anchor().screenStatePoint(liveFrame: builtInDisplayFrame)
        XCTAssertEqual(point, CGPoint(x: -1150, y: 400))
    }

    /// The reported bug: the window is dragged to the main display while the
    /// cursor is travelling, and the cursor finishes on the display the window
    /// just left.
    func testAnchorFollowsTheWindowOntoTheOtherDisplay() {
        let point = anchor().screenStatePoint(liveFrame: mainDisplayFrame)
        XCTAssertEqual(point, CGPoint(x: 850, y: 400))
    }

    /// Only the frame origin moves; the window-local offset must survive, so a
    /// click still lands on the same control inside the window.
    func testAnchorPreservesTheWindowLocalOffset() {
        let moved = CGRect(x: -1400, y: -600, width: 500, height: 400)
        let point = anchor().screenStatePoint(liveFrame: moved)
        XCTAssertEqual(point, CGPoint(x: -1150, y: -400))
    }

    /// A window that shrank must not put the cursor outside itself.
    func testAnchorClampsIntoASmallerLiveFrame() {
        let shrunk = CGRect(x: 600, y: 200, width: 120, height: 80)
        let point = anchor().screenStatePoint(liveFrame: shrunk)
        XCTAssertEqual(point, CGPoint(x: 720, y: 280))
    }

    /// No usable size means no re-derivation: the caller keeps the point it has
    /// rather than guessing.
    func testAnchorRejectsALiveFrameWithoutSize() {
        XCTAssertNil(anchor().screenStatePoint(liveFrame: .zero))
        XCTAssertNil(anchor().screenStatePoint(liveFrame: CGRect(x: 10, y: 10, width: 0, height: 40)))
        XCTAssertNil(anchor().screenStatePoint(liveFrame: .infinite))
        XCTAssertNil(anchor().screenStatePoint(liveFrame: CGRect(x: CGFloat.nan, y: 0, width: 50, height: 50)))
    }

    func testTrackerPrefersTheRegisteredLiveFrame() {
        CursorWindowFrameTracker.installFrameOverrideForTesting { windowID in
            windowID == 4242 ? self.mainDisplayFrame : nil
        }
        defer { CursorWindowFrameTracker.installFrameOverrideForTesting(nil) }

        XCTAssertEqual(CursorWindowFrameTracker.liveFrame(for: 4242), mainDisplayFrame)
        XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: 1))
    }

    /// An unknown window must not produce a frame out of thin air.
    func testTrackerReportsNothingForAnUnknownWindow() {
        CursorWindowFrameTracker.forgetAll()

        XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: CGWindowID(0)))
    }

    func testFailedRefreshKeepsLastUsableFrame() throws {
        let reads = DispatchSemaphore(value: 0), failedRead = DispatchSemaphore(value: 0)
        let frame = mainDisplayFrame
        CursorWindowFrameTracker.forgetAll()
        CursorWindowFrameTracker.installFrameReaderForTesting { _ in
            reads.signal()
            return frame
        }
        defer {
            CursorWindowFrameTracker.forgetAll()
            CursorWindowFrameTracker.installFrameReaderForTesting(nil)
        }
        CursorWindowFrameTracker.register(windowID: 1, element: nil)
        _ = CursorWindowFrameTracker.liveFrame(for: 1)
        XCTAssertEqual(reads.wait(timeout: .now() + 1), .success)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while CursorWindowFrameTracker.liveFrame(for: 1) == nil && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(CursorWindowFrameTracker.liveFrame(for: 1), frame)
        CursorWindowFrameTracker.installFrameReaderForTesting { _ in
            failedRead.signal()
            return nil
        }
        Thread.sleep(forTimeInterval: 0.04)
        XCTAssertEqual(CursorWindowFrameTracker.liveFrame(for: 1), frame)
        XCTAssertEqual(failedRead.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertEqual(CursorWindowFrameTracker.liveFrame(for: 1), frame)
    }

    /// The service registers the window while building a cursor target, but the
    /// overlay plays queued actions later. An earlier queued action that clears
    /// tracking (an unanchored target, a reset) must not drop the window a later
    /// action depends on.
    func testRegistrationKeepsItsPlaceInTheCursorQueue() {
        let reads = DispatchSemaphore(value: 0)
        CursorWindowFrameTracker.forgetAll()
        CursorWindowFrameTracker.installFrameReaderForTesting { _ in
            reads.signal()
            return nil
        }
        defer {
            CursorWindowFrameTracker.forgetAll()
            CursorWindowFrameTracker.installFrameReaderForTesting(nil)
        }
        let snapshot = AppSnapshot(
            app: RunningAppDescriptor(name: "Sample", bundleIdentifier: "com.example.Sample", pid: 18_465, runningApplication: .current),
            windowTitle: nil, windowBounds: builtInDisplayFrame, targetWindowID: 4242, targetWindowLayer: 0,
            screenshotData: nil, mode: .accessibility, treeLines: [], focusedSummary: nil, focusedElement: nil,
            selectedText: nil, windowElement: nil, elements: [:]
        )
        let drained = expectation(description: "cursor queue drained")
        Thread.detachNewThread {
            // Holds the main thread so the anchor below is built before this action plays.
            VisualCursorSupport.performOnMain {
                Thread.sleep(forTimeInterval: 0.1)
                CursorWindowFrameTracker.forgetAll()
            }
            _ = makeCursorWindowAnchor(snapshot: snapshot, windowLocalPoint: CGPoint(x: 250, y: 200))
            VisualCursorSupport.performOnMain { drained.fulfill() }
        }
        wait(for: [drained], timeout: 5)

        _ = CursorWindowFrameTracker.liveFrame(for: 4242)
        XCTAssertEqual(reads.wait(timeout: .now() + 1), .success, "the window is still tracked")
    }

    func testSlowReadDoesNotBlockOrQueueWorkAndCannotPublishAfterReplacement() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = builtInDisplayFrame, second = mainDisplayFrame
        CursorWindowFrameTracker.forgetAll()
        CursorWindowFrameTracker.installFrameReaderForTesting { id in
            if id == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                return first
            }
            return second
        }
        defer {
            release.signal()
            CursorWindowFrameTracker.forgetAll()
            CursorWindowFrameTracker.installFrameReaderForTesting(nil)
        }
        CursorWindowFrameTracker.register(windowID: 1, element: nil)
        XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: 1))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: 1)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
        CursorWindowFrameTracker.forgetAll()
        CursorWindowFrameTracker.register(windowID: 2, element: nil)
        XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: 1))
        XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: 2))
        release.signal()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var observed: CGRect?
        while observed == nil && ProcessInfo.processInfo.systemUptime < deadline {
            observed = CursorWindowFrameTracker.liveFrame(for: 2)
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(observed, second)
        XCTAssertNil(CursorWindowFrameTracker.liveFrame(for: 1))
        // No stale queued requests from the 1,000 render ticks may remain.
        XCTAssertEqual(entered.wait(timeout: .now() + 0.05), .timedOut)
    }
}
