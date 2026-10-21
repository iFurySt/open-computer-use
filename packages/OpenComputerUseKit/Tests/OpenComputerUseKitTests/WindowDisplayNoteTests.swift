import AppKit
import XCTest
@testable import OpenComputerUseKit

final class WindowDisplayNoteTests: XCTestCase {
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func app() -> RunningAppDescriptor {
        .init(name: "DisplayNoteFixture", bundleIdentifier: "test.display-note", pid: 42, runningApplication: .current)
    }

    private func snapshot(displayNote: String?) -> AppSnapshot {
        AppSnapshot(
            app: app(),
            windowTitle: "Offscreen",
            windowBounds: CGRect(x: 4000, y: 1200, width: 900, height: 700),
            targetWindowID: 7,
            targetWindowLayer: 0,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: ["1 button OK"],
            focusedSummary: nil,
            focusedElement: nil,
            selectedText: nil,
            windowElement: nil,
            elements: [:],
            displayNote: displayNote
        )
    }

    func testWindowOnAnActiveDisplayHasNoNote() {
        XCTAssertNil(windowDisplayNote(
            windowBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            activeDisplayBounds: [mainDisplay]
        ))
        // A window that only partially leaves the display is still visible.
        XCTAssertNil(windowDisplayNote(
            windowBounds: CGRect(x: -200, y: -50, width: 800, height: 600),
            activeDisplayBounds: [mainDisplay]
        ))
    }

    func testWindowBridgingTwoDisplaysHasNoNote() {
        let secondDisplay = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertNil(windowDisplayNote(
            windowBounds: CGRect(x: 1900, y: 100, width: 400, height: 300),
            activeDisplayBounds: [mainDisplay, secondDisplay]
        ))
    }

    func testWindowOutsideEveryActiveDisplayGetsNote() throws {
        let note = try XCTUnwrap(windowDisplayNote(
            windowBounds: CGRect(x: 4000, y: 1200, width: 900, height: 700),
            activeDisplayBounds: [mainDisplay]
        ))
        XCTAssertTrue(note.hasPrefix("--- display note ---"))
        XCTAssertTrue(note.contains("x=4000"))
        XCTAssertTrue(note.contains("y=1200"))
        XCTAssertTrue(note.contains("width=900"))
        XCTAssertTrue(note.contains("height=700"))
        XCTAssertTrue(note.contains("outside every active display"))
    }

    func testMissingBoundsOrDisplayListSkipsNote() {
        XCTAssertNil(windowDisplayNote(windowBounds: nil, activeDisplayBounds: [mainDisplay]))
        XCTAssertNil(windowDisplayNote(
            windowBounds: CGRect(x: 4000, y: 1200, width: 900, height: 700),
            activeDisplayBounds: []
        ))
        XCTAssertNil(windowDisplayNote(windowBounds: .zero, activeDisplayBounds: [mainDisplay]))
    }

    func testRenderedTextPlacesNoteBetweenWindowAndTree() throws {
        let note = try XCTUnwrap(windowDisplayNote(
            windowBounds: CGRect(x: 4000, y: 1200, width: 900, height: 700),
            activeDisplayBounds: [mainDisplay]
        ))
        let rendered = snapshot(displayNote: note).renderedText
        let windowRange = try XCTUnwrap(rendered.range(of: "Window:"))
        let noteRange = try XCTUnwrap(rendered.range(of: "--- display note ---"))
        let treeRange = try XCTUnwrap(rendered.range(of: "1 button OK"))
        XCTAssertLessThan(windowRange.lowerBound, noteRange.lowerBound)
        XCTAssertLessThan(noteRange.lowerBound, treeRange.lowerBound)
    }

    func testRenderedTextWithoutNoteKeepsTheExistingLayout() {
        let rendered = snapshot(displayNote: nil).renderedText
        XCTAssertFalse(rendered.contains("--- display note ---"))
        XCTAssertEqual(rendered.components(separatedBy: "\n").count, 3)
    }
}
