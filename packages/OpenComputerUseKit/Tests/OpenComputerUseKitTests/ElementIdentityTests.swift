import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class ElementIdentityTests: XCTestCase {
    private func button(_ title: String) -> ElementIdentity {
        ElementIdentity(role: "AXButton", subrole: nil, title: title, description: nil, identifier: nil, value: nil)
    }

    func testUnchangedIdentityAcceptedAndChangedOrMissingIdentityRefused() throws {
        XCTAssertNoThrow(try ElementIdentity.validate(index: "4", recorded: button("Alpha"), now: button("Alpha")))
        for now in [button("Beta"), nil] {
            XCTAssertThrowsError(try ElementIdentity.validate(index: "4", recorded: button("Alpha"), now: now)) { error in
                XCTAssertTrue(error.localizedDescription.contains("nothing was sent"))
            }
        }
        let unknown = ElementIdentity(role: nil, subrole: nil, title: nil, description: nil, identifier: nil, value: nil)
        XCTAssertThrowsError(try ElementIdentity.validate(index: "4", recorded: unknown, now: unknown))
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
