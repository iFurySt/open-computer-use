import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Every test uses a private named pasteboard; the user's clipboard is never read or written.
final class ClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ocu-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testReturnsPlainText() throws {
        pasteboard.setString("copied 中文🙂", forType: .string)
        XCTAssertEqual(try clipboardText(in: pasteboard), "copied 中文🙂")
    }

    func testWithholdsMarkedItems() {
        for marker in withheldPasteboardTypes {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("secret", forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            pasteboard.writeObjects([item])
            XCTAssertThrowsError(try clipboardText(in: pasteboard), marker) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertTrue(error.localizedDescription.contains("not returned"))
            }
        }
    }

    func testWithholdsWhenAnyItemIsMarked() {
        let plain = NSPasteboardItem()
        plain.setString("visible", forType: .string)
        let concealed = NSPasteboardItem()
        concealed.setString("secret", forType: .string)
        concealed.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([plain, concealed])
        XCTAssertThrowsError(try clipboardText(in: pasteboard))
    }

    func testRejectsNonTextAndEmptyText() {
        pasteboard.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
        XCTAssertThrowsError(try clipboardText(in: pasteboard)) { error in
            XCTAssertEqual(error.localizedDescription, "The clipboard holds no text.")
        }
        pasteboard.clearContents()
        pasteboard.setString("", forType: .string)
        XCTAssertThrowsError(try clipboardText(in: pasteboard))
    }

    func testBoundsTextSize() throws {
        pasteboard.setString(String(repeating: "a", count: clipboardTextLimit), forType: .string)
        XCTAssertEqual(try clipboardText(in: pasteboard).utf16.count, clipboardTextLimit)
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "a", count: clipboardTextLimit + 1), forType: .string)
        XCTAssertThrowsError(try clipboardText(in: pasteboard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("\(clipboardTextLimit + 1) UTF-16 code units"))
        }
    }

    func testWriteReplacesMarkedItemAndReadsBack() throws {
        guard LockedUseSession.current().state == .unlocked else {
            throw XCTSkip("Clipboard tools require a usable console session")
        }
        pasteboard.setString("secret", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let service = ComputerUseService()
        XCTAssertEqual(try service.writeClipboard(text: "prepared", pasteboard: pasteboard).primaryText, "ok")
        XCTAssertEqual(pasteboard.types?.map(\.rawValue).contains("org.nspasteboard.ConcealedType"), false)
        XCTAssertEqual(try service.readClipboard(pasteboard: pasteboard).primaryText, "prepared")
    }
}
