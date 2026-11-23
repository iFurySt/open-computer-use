import XCTest
@testable import OpenComputerUseKit

/// Pure record-filter tests for the targeted lookup. The native AX search and
/// window resolution need separate live desktop validation; the
/// criteria matching is pure string logic and verified here.
final class TargetedAXTests: XCTestCase {
    private func criteria(
        text: String? = nil,
        exact: Bool = false,
        role: String? = nil
    ) -> TargetedAX.Criteria {
        TargetedAX.Criteria(text: text, exact: exact, role: role, limit: 20, maxNodes: 500)
    }

    func testRoleEqualsToleratesAXPrefix() {
        XCTAssertTrue(targetedRoleEquals("AXButton", "button"))
        XCTAssertTrue(targetedRoleEquals("AXButton", "AXButton"))
        XCTAssertTrue(targetedRoleEquals("button", "AXButton"))
        XCTAssertFalse(targetedRoleEquals("AXButton", "textfield"))
        XCTAssertFalse(targetedRoleEquals(nil, "button"))
    }

    func testTextMatchesTitleDescriptionOrValueSubstring() {
        let c = criteria(text: "compose")
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "Compose", description: nil, value: nil))
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: nil, description: "Compose a message", value: nil))
        XCTAssertTrue(targetedRecordMatches(c, role: "AXTextField", title: nil, description: nil, value: "re: compose"))
        XCTAssertFalse(targetedRecordMatches(c, role: "AXButton", title: "Send", description: nil, value: "hi"))
    }

    func testTooltipAndIdentifierNameAControl() {
        XCTAssertTrue(targetedRecordMatches(criteria(text: "close"), role: "AXButton", title: nil, description: nil, value: nil, help: "Close panel"))
        XCTAssertTrue(targetedRecordMatches(criteria(text: "results", exact: true), role: "AXGroup", title: nil, description: nil, value: nil, identifier: "results"))
        XCTAssertFalse(targetedRecordMatches(criteria(text: "close"), role: "AXButton", title: nil, description: nil, value: nil, help: "Open", identifier: "panel"))
    }

    func testANamelessBoxOfLettersIsNamedByWhatItHolds() {
        // window > list > [a row drawn letter by letter, a blank between the words; a row holding one text]
        var roles: [String?] = ["AXWindow", "AXList", "AXGroup", "AXGroup", "AXStaticText"]
        var own: [String?] = ["Indicators", nil, nil, nil, "RSI Divergence"]
        var children: [[Int]] = [[1], [2, 3], [], [4], []]
        for letter in "RSI Strategy" {
            children[2].append(roles.count)
            roles.append("AXStaticText")
            own.append(letter == " " ? nil : String(letter))
            children.append([])
        }
        func named(_ c: TargetedAX.Criteria) -> [String] {
            namedByHeldText(c, roles: roles, own: own, children: children).map { "\($0.node) \($0.text)" }
        }

        XCTAssertEqual(named(criteria(text: "RSI Strategy")), ["2 RSI Strategy"])
        XCTAssertEqual(named(criteria(text: "rsi strategy", exact: true)), ["2 RSI Strategy"])
        // the other row's own text matches, so the walk finds that text and not its row
        XCTAssertEqual(named(criteria(text: "RSI")), ["2 RSI Strategy"])
        XCTAssertEqual(named(criteria(text: "RSI Strategy", role: "button")), [])
        // a node with text of its own keeps it: the walk matches it by that text
        XCTAssertEqual(named(criteria(text: "Indicators")), [])
        XCTAssertEqual(named(criteria(role: "group")), [])
    }

    func testExactRequiresFullMatch() {
        let c = criteria(text: "Compose", exact: true)
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "compose", description: nil, value: nil))
        XCTAssertFalse(targetedRecordMatches(c, role: "AXButton", title: "Compose mail", description: nil, value: nil))
    }

    func testRoleFilterCombinesWithText() {
        let c = criteria(text: "send", role: "button")
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "Send", description: nil, value: nil))
        // right text, wrong role
        XCTAssertFalse(targetedRecordMatches(c, role: "AXStaticText", title: "Send", description: nil, value: nil))
    }

    func testRoleOnlyMatchesAnyText() {
        let c = criteria(role: "AXButton")
        XCTAssertTrue(targetedRecordMatches(c, role: "AXButton", title: "anything", description: nil, value: nil))
        XCTAssertFalse(targetedRecordMatches(c, role: "AXTextField", title: "anything", description: nil, value: nil))
    }
}
