import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

/// A fresh cursor (new session, or after the 30 s idle hide) must not fly in from the screen
/// origin when there is a better place to start.
final class CursorFreshStartTests: XCTestCase {
    private let corner = defaultVisualCursorInitialTipPosition()

    func testStartsWhereTheCursorWasLastSeen() {
        XCTAssertEqual(
            visualCursorFreshStartTipPosition(lastSeen: CGPoint(x: 640, y: 420), pointer: CGPoint(x: 10, y: 10), fallback: corner),
            CGPoint(x: 640, y: 420)
        )
    }

    func testFirstEverMoveStartsAtTheRealPointerNotTheCorner() {
        XCTAssertEqual(
            visualCursorFreshStartTipPosition(lastSeen: nil, pointer: CGPoint(x: 900, y: 300), fallback: corner),
            CGPoint(x: 900, y: 300)
        )
        XCTAssertEqual(visualCursorFreshStartTipPosition(lastSeen: nil, pointer: nil, fallback: corner), corner)
    }
}
