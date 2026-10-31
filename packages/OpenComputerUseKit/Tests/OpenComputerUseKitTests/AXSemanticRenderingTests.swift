import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

/// Synthetic AX data, not expected renderer strings. Logical IDs below are the
/// independent oracle for controls and metadata that an agent must still reach.
final class AXSemanticRenderingTests: XCTestCase {
    private final class Node {
        let id: Int
        let element: AXUIElement
        var attributes: [String: CFTypeRef]
        var children: [Int] = []
        var actions: [String] = []
        var settable = false
        init(_ id: Int, role: String, title: String? = nil) {
            self.id = id
            self.element = AXUIElementCreateApplication(Int32(120_000 + id))
            attributes = ["AXRole": role as CFString, "AXEnabled": kCFBooleanTrue!]
            if let title { attributes["AXTitle"] = title as CFString }
            var point = CGPoint(x: 20 + id * 10, y: 30 + id * 10)
            var size = CGSize(width: 400, height: 200)
            attributes["AXPosition"] = AXValueCreate(.cgPoint, &point)
            attributes["AXSize"] = AXValueCreate(.cgSize, &size)
        }
    }

    private final class Fixture {
        var nodes: [Int: Node] = [:]
        init() {
            let window = add(0, role: "AXWindow", title: "Semantic fixture")
            window.attributes["AXSubrole"] = "AXStandardWindow" as CFString
            window.children = [1]
            let web = add(1, role: "AXWebArea", title: "Fixture page")
            web.attributes["AXURL"] = "https://example.invalid/fixture" as CFString
            web.children = [2]
            let wrapper = add(2, role: "AXGroup")
            wrapper.children = [3, 4]
            let button = add(3, role: "AXButton", title: "Submit")
            button.actions = ["AXPress"]
            let field = add(4, role: "AXTextField", title: "Email")
            field.attributes["AXValue"] = "person@example.invalid" as CFString
            field.settable = true
        }
        @discardableResult func add(_ id: Int, role: String, title: String? = nil) -> Node {
            let node = Node(id, role: role, title: title)
            nodes[id] = node
            return node
        }
        func node(_ element: AXUIElement) -> Node {
            nodes.values.first { CFEqual($0.element, element) }!
        }
        func render(focused: Int? = nil) -> (lines: [String], records: [Int: ElementRecord]) {
            let cache = AXSnapshotReadCache(batch: { element in
                let node = self.node(element)
                var values = node.attributes.mapValues { AXSnapshotReadCache.Attribute.value($0) }
                values["AXChildren"] = .value(node.children.map { self.nodes[$0]!.element } as CFArray)
                return values
            }, single: { _, _ in (.attributeUnsupported, nil) }, actions: { element in
                (.success, self.node(element).actions)
            }, settable: { element, attribute in
                (.success, attribute == "AXValue" && self.node(element).settable)
            })
            return AXSnapshotReadCache.withCache(cache) {
                renderAXSemanticFixture(root: nodes[0]!.element, focused: focused.flatMap { nodes[$0]?.element })
            }
        }
        func index(_ logicalID: Int, in records: [Int: ElementRecord]) -> Int? {
            records.first { _, record in record.element.map { CFEqual($0, nodes[logicalID]!.element) } == true }?.key
        }
    }

    private func assertAgentTargets(_ fixture: Fixture, _ output: (lines: [String], records: [Int: ElementRecord]),
                                    expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for logicalID in expected {
            guard let index = fixture.index(logicalID, in: output.records), let record = output.records[index] else {
                XCTFail("Lost semantic target \(logicalID)", file: file, line: line); continue
            }
            XCTAssertEqual(record.index, index, file: file, line: line)
            XCTAssertEqual(record.role, fixture.nodes[logicalID]!.attributes["AXRole"] as? String, file: file, line: line)
            XCTAssertTrue(output.lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(index) ") }, file: file, line: line)
        }
        let text = output.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Submit"), file: file, line: line)
        XCTAssertTrue(text.contains("Email"), file: file, line: line)
        XCTAssertTrue(text.contains("person@example.invalid"), file: file, line: line)
        if let index = fixture.index(3, in: output.records) {
            XCTAssertEqual(output.records[index]?.rawActions, ["AXPress"], file: file, line: line)
            XCTAssertNotNil(output.records[index]?.localFrame, file: file, line: line)
        }
    }

    func testBaselineSemanticOracleIncludesControlsAndBackedActionIndexes() {
        let fixture = Fixture()
        let output = fixture.render()
        assertAgentTargets(fixture, output, expected: [0, 1, 3, 4])
        XCTAssertNotNil(fixture.index(2, in: output.records))
    }

    func testSemanticGroupsAndActionTargetsAreNeverStructuralNoise() {
        let cases: [(String, (Node) -> Void, Int?)] = [
            ("named", { $0.attributes["AXTitle"] = "Billing" as CFString }, nil),
            ("described", { $0.attributes["AXDescription"] = "Shipping" as CFString }, nil),
            ("help", { $0.attributes["AXHelp"] = "Use this group to submit" as CFString }, nil),
            ("identifier", { $0.attributes["AXIdentifier"] = "payment-group" as CFString }, nil),
            ("value", { $0.attributes["AXValue"] = "ready" as CFString }, nil),
            ("selected", { $0.attributes["AXSelected"] = kCFBooleanTrue }, nil),
            ("expanded", { $0.attributes["AXExpanded"] = kCFBooleanTrue }, nil),
            ("disabled", { $0.attributes["AXEnabled"] = kCFBooleanFalse }, nil),
            ("placeholder", { $0.attributes["AXPlaceholderValue"] = "Choose a plan" as CFString }, nil),
            ("settable", { $0.settable = true; $0.attributes["AXValue"] = "" as CFString }, nil),
            ("primary action", { $0.actions = ["AXPress"] }, nil),
            ("secondary action", { $0.actions = ["AXShowMenu"] }, nil),
            ("subrole", { $0.attributes["AXSubrole"] = "AXLandmarkNavigation" as CFString }, nil),
            ("focused", { _ in }, 2),
        ]
        for (name, configure, focus) in cases {
            let fixture = Fixture(); configure(fixture.nodes[2]!)
            let output = fixture.render(focused: focus)
            assertAgentTargets(fixture, output, expected: [0, 1, 2, 3, 4])
            XCTAssertNotNil(fixture.index(2, in: output.records), name)
            let text = output.lines.joined(separator: "\n")
            for attribute in ["AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXValue", "AXPlaceholderValue"] {
                if let value = fixture.nodes[2]!.attributes[attribute] as? String, !value.isEmpty {
                    XCTAssertTrue(text.contains(value), "Lost \(attribute) in \(name)")
                }
            }
            if ["selected", "expanded", "disabled"].contains(name) { XCTAssertTrue(text.contains(name), name) }
        }
    }

    func testScalarValuesAndLiteralFormatLikeTextRemainVisible() {
        let fixture = Fixture()
        let toggle = fixture.add(5, role: "AXCheckBox", title: "Enabled")
        toggle.attributes["AXValue"] = kCFBooleanFalse
        toggle.actions = ["AXPress"]; toggle.settable = true
        let slider = fixture.add(6, role: "AXSlider", title: "Volume")
        slider.attributes["AXValue"] = NSNumber(value: 0.75)
        slider.actions = ["AXIncrement", "AXDecrement"]; slider.settable = true
        let code = fixture.add(7, role: "AXTextField", title: "Numeric code")
        code.attributes["AXValue"] = "0042" as CFString; code.settable = true
        let literal = fixture.add(8, role: "AXTextField", title: "Literal (w:str)")
        literal.attributes["AXValue"] = "a = b (settable, string)" as CFString; literal.settable = true
        fixture.nodes[2]!.children.append(contentsOf: [5, 6, 7, 8])
        let output = fixture.render()
        assertAgentTargets(fixture, output, expected: [0, 1, 3, 4, 5, 6, 7, 8])
        let text = output.lines.joined(separator: "\n")
        for value in ["off", "0.75", "0042", "Literal (w:str)", "a = b (settable, string)"] {
            XCTAssertTrue(text.contains(value), value)
        }
    }

    func testNamedCompactActionTargetKeepsItsFrameText() {
        let fixture = Fixture()
        let node = fixture.nodes[2]!
        node.attributes["AXTitle"] = "Named action" as CFString
        var size = CGSize(width: 80, height: 30)
        node.attributes["AXSize"] = AXValueCreate(.cgSize, &size)
        node.children = []
        node.actions = ["AXPress"]
        let output = fixture.render()
        let row = output.lines.first { $0.contains("Named action") }
        XCTAssertTrue(row?.contains("Frame:") == true, row ?? "Missing named action")
    }

    func testRetainedElementHandlesDoNotRetainOldValuesAcrossReads() {
        let fixture = Fixture()
        let before = fixture.render()
        fixture.nodes[4]!.attributes["AXValue"] = "updated@example.invalid" as CFString
        let after = withExtendedLifetime(before) { fixture.render() }
        XCTAssertTrue(before.lines.joined(separator: "\n").contains("person@example.invalid"))
        XCTAssertTrue(after.lines.joined(separator: "\n").contains("updated@example.invalid"))
        XCTAssertFalse(after.lines.joined(separator: "\n").contains("person@example.invalid"))
        let old = before.records[fixture.index(4, in: before.records)!]!
        let new = after.records[fixture.index(4, in: after.records)!]!
        XCTAssertTrue(CFEqual(old.element!, new.element!))
    }

    func testRepeatedControlNamesRemainDistinctActionTargets() {
        let fixture = Fixture()
        let second = fixture.add(5, role: "AXButton", title: "Submit")
        second.actions = ["AXPress"]
        fixture.nodes[2]!.children.append(5)
        let output = fixture.render()
        assertAgentTargets(fixture, output, expected: [0, 1, 3, 4, 5])
        XCTAssertNotEqual(fixture.index(3, in: output.records), fixture.index(5, in: output.records))
    }
}
