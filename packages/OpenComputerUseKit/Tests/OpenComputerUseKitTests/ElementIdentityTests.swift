import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class ElementIdentityTests: XCTestCase {
    private func button(_ title: String) -> ElementIdentity {
        ElementIdentity(role: "AXButton", subrole: nil, title: title, description: nil, identifier: nil, value: nil)
    }

    private func rebind(_ recorded: ElementIdentity, now: ElementIdentity?, window: [(String, ElementIdentity)],
                        complete: Bool = true) throws -> String? {
        try ElementIdentity.rebind(index: "4", recorded: recorded, now: now, candidates: {
            (window.map { (element: $0.0, identity: $0.1) }, complete)
        })
    }

    private func assertRefused(_ body: () throws -> String?, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), message, file: file, line: line) { error in
            XCTAssertTrue((error as? ComputerUseError)?.errorDescription?.hasSuffix("(nothing was sent)") == true, file: file, line: line)
        }
    }

    func testAnUnchangedControlActsAndASwappedOneIsBoundToTheOneThatNowIsIt() throws {
        XCTAssertNil(try rebind(button("Alpha"), now: button("Alpha"), window: []))
        // The snapshot showed Alpha at this index; the two buttons swapped titles before the click.
        XCTAssertEqual(try rebind(button("Alpha"), now: button("Beta"), window: [("kept", button("Beta")), ("other", button("Alpha"))]), "other")
        XCTAssertEqual(try rebind(button("Alpha"), now: nil, window: [("rerendered", button("Alpha"))]), "rerendered", "a re-rendered control")
    }

    func testNoneSeveralOrACutSearchIsRefused() {
        XCTAssertThrowsError(try rebind(button("Alpha"), now: button("Gamma"), window: [("kept", button("Gamma"))])) { error in
            XCTAssertEqual(
                (error as? ComputerUseError)?.errorDescription,
                "element 4 is no longer the AXButton \"Alpha\" the snapshot showed, and no element now is; call get_app_state again (nothing was sent)"
            )
        }
        assertRefused({ try self.rebind(self.button("Alpha"), now: nil, window: [("a", self.button("Alpha")), ("b", self.button("Alpha"))]) }, "two")
        assertRefused({ try self.rebind(self.button("Alpha"), now: nil, window: [("a", self.button("Alpha"))], complete: false) }, "cut short")
    }

    /// A field's value is what was typed and a checkbox's its state: filling a field or toggling a checkbox doesn't
    /// make it another control. Static text's value is its name, so changed text is another element.
    func testOnlyAValueThatNamesTheControlCounts() {
        func field(_ value: String) -> ElementIdentity {
            ElementIdentity(role: "AXTextField", subrole: nil, title: nil, description: "Email", identifier: "email", value: value)
        }
        func checkbox(_ value: String) -> ElementIdentity {
            ElementIdentity(role: "AXCheckBox", subrole: nil, title: "Remember", description: nil, identifier: nil, value: value)
        }
        func text(_ value: String) -> ElementIdentity {
            ElementIdentity(role: "AXStaticText", subrole: nil, title: nil, description: nil, identifier: nil, value: value)
        }
        XCTAssertEqual(field(""), field("first fill"))
        XCTAssertEqual(checkbox("0"), checkbox("1"))
        XCTAssertNotEqual(text("Saved"), text("Saving…"))
        XCTAssertNotEqual(button("Save"), ElementIdentity(role: "AXButton", subrole: nil, title: "Save", description: nil, identifier: "save", value: nil))
        XCTAssertNotEqual(button("Close"), ElementIdentity(role: "AXButton", subrole: "AXCloseButton", title: "Close", description: nil, identifier: nil, value: nil))
        XCTAssertEqual(ElementIdentity(role: "AXButton", subrole: nil, title: " ", description: "Close", identifier: nil, value: nil).name, "Close",
                       "the name is the title, else the description")
    }
}
