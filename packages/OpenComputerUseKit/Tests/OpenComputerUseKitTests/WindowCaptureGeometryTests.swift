import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class WindowCaptureGeometryTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let bounds = CGRect(x: 20, y: 30, width: 400, height: 200)

    private func image(_ width: Int = 800, _ height: Int = 400) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testContainedWindowKeepsHardwareFastPath() {
        let hardware = image()
        let result = WindowCaptureGeometry.capture(bounds: bounds, displayBounds: [display], hardware: { hardware }, fullWindow: {
            XCTFail("A valid hardware capture must not call ScreenCaptureKit")
            return nil
        })
        XCTAssertTrue(result === hardware)
    }

    func testOffscreenSpanningAndUnknownDisplaysUseFullWindow() {
        let full = image()
        let other = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        for (window, displays) in [
            (CGRect(x: -100, y: 30, width: 400, height: 200), [display]),
            (CGRect(x: 800, y: 30, width: 400, height: 200), [display]),
            (CGRect(x: 800, y: 30, width: 400, height: 200), [display, other]),
            (bounds, []),
        ] {
            let result = WindowCaptureGeometry.capture(bounds: window, displayBounds: displays, hardware: {
                XCTFail("Do not use hardware even if a cropped image happens to have the correct aspect ratio")
                return self.image()
            }, fullWindow: { full })
            XCTAssertTrue(result === full)
        }
    }

    func testHardwareFailureOrCropFallsBackAndBadFullCaptureIsRejected() {
        let full = image()
        for hardware in [nil, image(600, 400)] {
            XCTAssertTrue(WindowCaptureGeometry.capture(bounds: bounds, displayBounds: [display],
                hardware: { hardware }, fullWindow: { full }) === full)
        }
        XCTAssertNil(WindowCaptureGeometry.capture(bounds: bounds, displayBounds: [],
            hardware: { self.image() }, fullWindow: { self.image(600, 400) }))
        XCTAssertNil(WindowCaptureGeometry.capture(bounds: bounds, displayBounds: [],
            hardware: { self.image() }, fullWindow: { nil }))
    }

    func testInvalidBoundsDoNotStartCapture() {
        for frame in [CGRect.zero, .null, .infinite,
                      CGRect(x: CGFloat.nan, y: 0, width: 400, height: 200),
                      CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 200)] {
            XCTAssertNil(WindowCaptureGeometry.capture(bounds: frame, displayBounds: [display], hardware: {
                XCTFail("Invalid geometry must not reach capture"); return nil
            }, fullWindow: { XCTFail("Invalid geometry must not reach capture"); return nil }))
        }
    }

    func testPixelRoundingAndInvalidPixelSizes() {
        XCTAssertTrue(WindowCaptureGeometry.matchesFullWindow(pixelSize: CGSize(width: 799, height: 400), bounds: bounds))
        XCTAssertFalse(WindowCaptureGeometry.matchesFullWindow(pixelSize: CGSize(width: 790, height: 400), bounds: bounds))
        for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 400), CGSize(width: 800, height: CGFloat.infinity)] {
            XCTAssertFalse(WindowCaptureGeometry.matchesFullWindow(pixelSize: size, bounds: bounds))
        }
    }

    func testAXGeometryPreservesZeroSizesButRejectsNonFiniteNegativeAndOverflow() {
        XCTAssertEqual(validatedAXFrame(position: CGPoint(x: 25, y: 40), size: .zero, windowBounds: bounds),
                       CGRect(x: 5, y: 10, width: 0, height: 0))
        for bad in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertNil(validatedAXFrame(position: CGPoint(x: bad, y: 0), size: CGSize(width: 10, height: 20)))
            XCTAssertNil(validatedAXFrame(position: .zero, size: CGSize(width: 10, height: bad)))
        }
        XCTAssertNil(validatedAXFrame(position: .zero, size: CGSize(width: -1, height: 20)))
        let huge = CGFloat.greatestFiniteMagnitude
        XCTAssertNil(validatedAXFrame(position: CGPoint(x: huge, y: 0), size: CGSize(width: huge, height: 20)))
        XCTAssertNil(validatedAXFrame(position: CGPoint(x: huge, y: 0), size: .zero,
                                     windowBounds: CGRect(x: -huge, y: 0, width: 10, height: 20)))
    }
}
