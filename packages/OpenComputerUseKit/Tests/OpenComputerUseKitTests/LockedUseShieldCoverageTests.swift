import XCTest
@testable import OpenComputerUseKit

final class LockedUseShieldCoverageTests: XCTestCase {
    func testQuartzDisplayAtNegativeOriginAndOversizedSurface() {
        let display = CGRect(x: -1512, y: 1440, width: 1512, height: 982)
        XCTAssertTrue(LockedUseShieldCoverage.covers(display, display: display))
        XCTAssertTrue(LockedUseShieldCoverage.covers(display.insetBy(dx: -1, dy: -1), display: display))
        XCTAssertFalse(LockedUseShieldCoverage.covers(display.insetBy(dx: 75, dy: 49), display: display))
        for offset in [CGPoint(x: 0.01, y: 0), CGPoint(x: -0.01, y: 0),
                       CGPoint(x: 0, y: 0.01), CGPoint(x: 0, y: -0.01)] {
            XCTAssertFalse(LockedUseShieldCoverage.covers(
                display.offsetBy(dx: offset.x, dy: offset.y), display: display))
        }
    }

    func testOverscanStillRequiresRealFullCoverageDuringTransition() {
        for display in [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                        CGRect(x: -1512, y: 1440, width: 1512, height: 982)] {
            let surface = LockedUseShieldCoverage.surfaceFrame(for: display)
            XCTAssertEqual(surface.midX, display.midX)
            XCTAssertEqual(surface.midY, display.midY)
            for scale in [1.0, 0.9375, 0.9, 0.75] {
                let actual = CGRect(x: display.midX - surface.width * scale / 2,
                                    y: display.midY - surface.height * scale / 2,
                                    width: surface.width * scale, height: surface.height * scale)
                XCTAssertTrue(LockedUseShieldCoverage.covers(actual, display: display))
            }
            XCTAssertFalse(LockedUseShieldCoverage.covers(display.insetBy(dx: 1, dy: 1), display: display))
        }
    }

    func testInvalidGeometryCannotAuthorizeCoverage() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        for invalid in [CGRect.null, .infinite, .zero,
                        CGRect(x: 0, y: 0, width: -100, height: 100),
                        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)] {
            XCTAssertFalse(LockedUseShieldCoverage.covers(invalid, display: display))
            XCTAssertFalse(LockedUseShieldCoverage.covers(display, display: invalid))
        }
    }

    /// Measured on macOS 26.4.1 with the 1920x1080 agent virtual display at
    /// Quartz {-1920, 0}: passing the global frame to init produced WindowServer
    /// bounds {{-4320, -843}, {2880, 1620}} (shieldBoundsMismatch). The local
    /// rect produced {{-2400, -270}, {2880, 1620}}, which covers the display.
    func testSecondaryScreenInitRectIsScreenLocal() {
        let screenOrigin = CGPoint(x: -1920, y: 573)
        let global = LockedUseShieldCoverage.surfaceFrame(for: CGRect(origin: screenOrigin, size: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(global, CGRect(x: -2400, y: 303, width: 2880, height: 1620))
        let local = LockedUseShieldCoverage.screenLocalRect(global, screenOrigin: screenOrigin)
        XCTAssertEqual(local, CGRect(x: -480, y: -270, width: 2880, height: 1620))
        // AppKit adds the screen origin back: the window must land on the global frame.
        XCTAssertEqual(local.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y), global)
        // Measured WindowServer bounds before/after the fix, against Quartz display bounds.
        let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(LockedUseShieldCoverage.covers(CGRect(x: -4320, y: -843, width: 2880, height: 1620), display: display))
        XCTAssertTrue(LockedUseShieldCoverage.covers(CGRect(x: -2400, y: -270, width: 2880, height: 1620), display: display))
    }

    func testPrimaryScreenLocalRectIsUnchanged() {
        let global = LockedUseShieldCoverage.surfaceFrame(for: CGRect(x: 0, y: 0, width: 2557, height: 1653))
        XCTAssertEqual(LockedUseShieldCoverage.screenLocalRect(global, screenOrigin: .zero), global)
    }
}
