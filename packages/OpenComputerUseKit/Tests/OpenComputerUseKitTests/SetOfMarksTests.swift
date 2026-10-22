import AppKit
import XCTest
@testable import OpenComputerUseKit

final class SetOfMarksTests: XCTestCase {
    private func record(_ index: Int, _ role: String, _ frame: CGRect?, actions: [String] = [], synthetic: Bool = false, enabled: Bool = true) -> ElementRecord {
        ElementRecord(index: index, identifier: nil, element: nil, localFrame: frame, role: role,
                      rawActions: actions, prettyActions: [], isSyntheticText: synthetic, isEnabled: enabled)
    }

    func testMarksGoOnActionableElementsInsideTheWindowNumberedByElementIndex() {
        let records = [
            record(0, "AXWindow", CGRect(x: 0, y: 0, width: 400, height: 300), actions: ["AXRaise"]),
            record(3, "AXButton", CGRect(x: 10, y: 10, width: 60, height: 20), actions: ["AXPress"]),
            record(4, "AXStaticText", CGRect(x: 10, y: 40, width: 60, height: 20)),
            record(5, "AXTextField", CGRect(x: 10, y: 70, width: 200, height: 22)),
            record(6, "AXRow", CGRect(x: 0, y: 100, width: 400, height: 24)),
            record(7, "AXButton", CGRect(x: 500, y: 10, width: 60, height: 20), actions: ["AXPress"]),
            record(8, "AXGroup", CGRect(x: 0, y: 130, width: 400, height: 80), actions: ["AXShowMenu"]),
            record(9, "AXButton", CGRect(x: CGFloat.nan, y: 10, width: 60, height: 20), actions: ["AXPress"]),
            record(10, "AXButton", CGRect(x: 80, y: 10, width: 0, height: 20), actions: ["AXPress"]),
            record(11, "text", CGRect(x: 10, y: 220, width: 60, height: 20), actions: ["AXPress"], synthetic: true),
            record(13, "AXButton", CGRect(x: 100, y: 250, width: 60, height: 20), actions: ["AXPress"], enabled: false),
            record(12, "AXSlider", CGRect(x: 380, y: 280, width: 100, height: 40), actions: ["AXIncrement", "AXDecrement"]),
        ]
        let marks = screenshotMarks(for: Dictionary(uniqueKeysWithValues: records.map { ($0.index, $0) }),
                                    windowSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(marks.map(\.number), [3, 5, 6, 12])
        XCTAssertEqual(marks.first?.box, CGRect(x: 10, y: 10, width: 60, height: 20))
    }

    func testZoomBoxMapsMarksOntoTheCropAndPixelsBackToWindowPoints() {
        let window = CGRect(x: 300, y: 200, width: 800, height: 600)
        let zoom = CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        let region = zoomRegion(zoom, of: window.size)
        XCTAssertEqual(region, CGRect(x: 400, y: 150, width: 400, height: 300))
        // A Retina capture is 1600×1200; the crop is its matching 800×600 pixels.
        XCTAssertEqual(zoomRegion(zoom, of: CGSize(width: 1600, height: 1200)), CGRect(x: 800, y: 300, width: 800, height: 600))

        let mark = ScreenshotMark(number: 7, box: CGRect(x: 500, y: 200, width: 40, height: 20))
        let onCrop = rescaledScreenshotMarks([mark], from: region, to: CGSize(width: 800, height: 600))
        XCTAssertEqual(onCrop, [ScreenshotMark(number: 7, box: CGRect(x: 200, y: 100, width: 80, height: 40))])
        // The encoder then shrinks the crop to its delivered size; the mark follows.
        let delivered = rescaledScreenshotMarks(onCrop, from: CGRect(x: 0, y: 0, width: 800, height: 600), to: CGSize(width: 400, height: 300))
        XCTAssertEqual(delivered.first?.box, CGRect(x: 100, y: 50, width: 40, height: 20))

        // A click at the mark's centre in the delivered picture lands on the element.
        let point = screenshotPixelToWindowPoint(CGPoint(x: 120, y: 60), screenshotPixelSize: CGSize(width: 400, height: 300),
                                                 windowBounds: window, zoom: zoom)
        XCTAssertEqual(point, CGPoint(x: 520, y: 210))
        XCTAssertEqual(screenshotPixelToWindowPoint(CGPoint(x: 120, y: 60), screenshotPixelSize: CGSize(width: 400, height: 300),
                                                    windowBounds: window), CGPoint(x: 240, y: 120))
    }

    func testLabelsSitOutsideTheCornerWhenThereIsRoomAndNeverOverlap() {
        let picture = CGRect(x: 0, y: 0, width: 200, height: 100)
        let size = CGSize(width: 12, height: 14)
        let boxes = [
            CGRect(x: 40, y: 50, width: 50, height: 20),   // room above
            CGRect(x: 0, y: 0, width: 60, height: 30),     // on the top edge: inside its corner
            CGRect(x: 0, y: 0, width: 30, height: 10),     // same corner, inside the box above: moved right
            CGRect(x: 120, y: 40, width: 50, height: 20),  // above is another box: to its left
            CGRect(x: 110, y: 20, width: 80, height: 18),
        ]
        let labels = screenshotMarkLabels(boxes: boxes, sizes: Array(repeating: size, count: boxes.count), in: picture)
        XCTAssertEqual(labels.count, boxes.count)
        XCTAssertEqual(labels[0], CGRect(x: 40, y: 36, width: 12, height: 14))
        XCTAssertEqual(labels[1], CGRect(x: 0, y: 0, width: 12, height: 14))
        XCTAssertEqual(labels[2], CGRect(x: 12, y: 0, width: 12, height: 14))
        XCTAssertEqual(labels[3], CGRect(x: 108, y: 40, width: 12, height: 14))
        for (i, a) in labels.enumerated() {
            XCTAssertTrue(picture.contains(a))
            for b in labels[(i + 1)...] { XCTAssertFalse(a.intersects(b)) }
        }
    }

    func testDrawnOutlineKeepsTheSizeAndUsesATopLeftOrigin() throws {
        let width = 100, height = 80
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let blank = try XCTUnwrap(context.makeImage())
        let marked = try XCTUnwrap(drawingScreenshotMarks([ScreenshotMark(number: 4, box: CGRect(x: 30, y: 50, width: 40, height: 20))], on: blank))
        XCTAssertEqual(marked.width, width)
        XCTAssertEqual(marked.height, height)
        let bitmap = NSBitmapImageRep(cgImage: marked)
        func isWhite(_ x: Int, _ y: Int) -> Bool { (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.99 }
        // NSBitmapImageRep reads from the top-left: the left edge of a box 50 points down is drawn there.
        XCTAssertFalse(isWhite(30, 60))
        XCTAssertTrue(isWhite(50, 60))
        XCTAssertTrue(isWhite(30, 25))
        // Its number sits above the box's corner.
        XCTAssertFalse(isWhite(31, 40))
    }

    func testMarkedScreenshotIsDeliveredAtTheUnmarkedSize() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let image = try XCTUnwrap(context.makeImage())
        let config = ImageCaptureConfig.resolve(image: ["format": "jpg", "maxLongEdgePixels": 1000], environment: [:])
        let marks = [ScreenshotMark(number: 1, box: CGRect(x: 100, y: 100, width: 400, height: 200))]
        for data in [encodeScreenshot(for: image, config: config).data, encodeScreenshot(for: image, config: config, marks: marks).data] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(data) as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual([decoded.width, decoded.height], [1000, 500])
        }
    }

    func testMarksAndZoomNeedTheirChannelsAndAZoomInsideTheWindow() throws {
        XCTAssertNoThrow(try SnapshotObservationOptions(marks: true, zoom: CGRect(x: 0.7, y: 0, width: 0.3, height: 1)).validate())
        XCTAssertNoThrow(try SnapshotObservationOptions(includeAX: false, zoom: CGRect(x: 0, y: 0, width: 1, height: 1)).validate())
        for options in [SnapshotObservationOptions(includeScreenshot: false, marks: true), .init(includeAX: false, marks: true)] {
            XCTAssertThrowsError(try options.validate()) { XCTAssertTrue(String(describing: $0).contains("marks requires include_ax and include_screenshot")) }
        }
        XCTAssertThrowsError(try SnapshotObservationOptions(includeScreenshot: false, zoom: CGRect(x: 0, y: 0, width: 1, height: 1)).validate()) {
            XCTAssertTrue(String(describing: $0).contains("zoom requires include_screenshot"))
        }
        for zoom in [CGRect(x: 0.5, y: 0, width: -0.2, height: 1), CGRect(x: 0.6, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0, width: 0, height: 0.5),
                     CGRect(x: 0, y: CGFloat.nan, width: 0.5, height: 0.5)] {
            XCTAssertThrowsError(try SnapshotObservationOptions(zoom: zoom).validate()) {
                XCTAssertTrue(String(describing: $0).contains("zoom must be fractions of the window"))
            }
        }
    }

    func testDispatcherParsesMarksAndZoomBeforeResolvingTheApp() {
        let dispatcher = ComputerUseToolDispatcher()
        let cases: [([String: Any], String)] = [
            (["marks": "true"], "marks must be a boolean"),
            (["marks": 1], "marks must be a boolean"),
            (["zoom": [0, 0, 0.5, 0.5]], "zoom must be an object"),
            (["zoom": ["x": 0, "y": 0, "width": 0.5]], "zoom must be an object"),
            (["zoom": ["x": 0, "y": 0, "width": true, "height": 0.5]], "zoom must be an object"),
            (["zoom": ["x": 0.8, "y": 0, "width": 0.5, "height": 0.5]], "zoom must be fractions"),
            (["marks": true, "include_screenshot": false], "marks requires"),
        ]
        for (arguments, message) in cases {
            XCTAssertThrowsError(try dispatcher.callTool(name: "get_app_state", arguments: arguments.merging(["app": "missing-test-app"]) { $1 })) {
                XCTAssertTrue(String(describing: $0).contains(message), "\(arguments): \($0)")
            }
        }
    }

    func testSchemaDescribesMarksAndZoom() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "get_app_state" })
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let marks = try XCTUnwrap(properties["marks"] as? [String: Any])
        XCTAssertEqual(marks["type"] as? String, "boolean")
        XCTAssertEqual(marks["default"] as? Bool, false)
        XCTAssertTrue((marks["description"] as? String)?.contains("element_index") == true)
        let zoom = try XCTUnwrap(properties["zoom"] as? [String: Any])
        XCTAssertEqual(zoom["type"] as? String, "object")
        XCTAssertEqual(zoom["required"] as? [String], ["x", "y", "width", "height"])
        XCTAssertEqual(zoom["additionalProperties"] as? Bool, false)
        XCTAssertEqual(((zoom["properties"] as? [String: [String: Any]])?["width"])?["maximum"] as? Int, 1)
    }
}
