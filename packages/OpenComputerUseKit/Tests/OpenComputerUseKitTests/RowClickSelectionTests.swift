import AppKit
import XCTest
@testable import OpenComputerUseKit

/// A row whose cell is an editable text field: its AXConfirm starts editing the cell, where a
/// click selects the row.
final class RowClickSelectionTests: XCTestCase {
    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let field = NSTextField(string: "OCU editable row \(row + 1)")
            let cell = NSTableCellView()
            cell.textField = field
            cell.addSubview(field)
            field.frame = CGRect(x: 2, y: 0, width: 200, height: 17)
            return cell
        }
    }

    @MainActor
    func testClickSelectsARowWhoseCellIsEditableWithoutEditingIt() throws {
        do { try requireUsableComputerUseSession() }
        catch { throw XCTSkip("Service integration requires an unlocked session and a trusted test host: \(error)") }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 260, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let rows = Rows()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("rows")))
        table.dataSource = rows
        table.delegate = rows
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = table
        window.contentView?.addSubview(scroll)
        NSApplication.shared.finishLaunching()
        window.orderBack(nil)
        defer { window.close() }
        table.reloadData()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard AXIsProcessTrusted(), let app = AppDiscovery.runningApps().first(where: { $0.pid == getpid() }) else {
            throw XCTSkip("Live AX test application is unavailable")
        }

        let service = ComputerUseService()
        let result = try service.query(app: app.bundleIdentifier ?? app.name, role: "row",
                                       windowID: CGWindowID(window.windowNumber))
        let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 3)
        let index = try XCTUnwrap(matches[1]["index"] as? Int)
        _ = try service.click(app: app.bundleIdentifier ?? app.name, elementIndex: String(index),
                              x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .accessibility)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertFalse((window.firstResponder as? NSTextView)?.isFieldEditor == true, "the click must not start editing the cell")
    }
}
