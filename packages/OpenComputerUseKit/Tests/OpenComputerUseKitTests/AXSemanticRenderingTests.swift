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
        func render(focused: Int? = nil, compact: Bool = false, indentation: AXTreeIndentationStyle = .tab4) -> (lines: [String], records: [Int: ElementRecord]) {
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
                renderAXSemanticFixture(root: nodes[0]!.element, focused: focused.flatMap { nodes[$0]?.element },
                                        compactText: compact, indentationStyle: indentation)
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

    func testStructuralContainersAndTheirChildTargetsRemainAddressable() {
        let fixture = Fixture()
        let before = fixture.render(compact: false)
        let after = fixture.render(compact: true)
        assertAgentTargets(fixture, before, expected: [0, 1, 3, 4])
        assertAgentTargets(fixture, after, expected: [0, 1, 3, 4])
        XCTAssertNotNil(fixture.index(2, in: before.records))
        XCTAssertNotNil(fixture.index(2, in: after.records))
        XCTAssertEqual(Set(before.records.keys), Set(after.records.keys))
        XCTAssertLessThan(after.lines.joined(separator: "\n").count, before.lines.joined(separator: "\n").count)
        let newButtonIndex = fixture.index(3, in: after.records)!
        XCTAssertTrue(CFEqual(after.records[newButtonIndex]!.element!, fixture.nodes[3]!.element))
        XCTAssertEqual(after.records[newButtonIndex]!.rawActions, ["AXPress"])
    }

    func testBothFormatsPreserveNamesValuesAndControlRoles() {
        let fixture = Fixture()
        for compact in [false, true] {
            assertAgentTargets(fixture, fixture.render(compact: compact), expected: [0, 1, 2, 3, 4])
        }
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
            let output = fixture.render(focused: focus, compact: true)
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
        for compact in [false, true] {
            let output = fixture.render(compact: compact)
            assertAgentTargets(fixture, output, expected: [0, 1, 3, 4, 5, 6, 7, 8])
            let text = output.lines.joined(separator: "\n")
            for value in ["off", "0.75", "0042", "Literal (w:str)", "a = b (settable, string)"] {
                XCTAssertTrue(text.contains(value), value)
            }
        }
    }

    func testCompactFormattingKeepsEveryRecordAndItsHierarchy() {
        let fixture = Fixture()
        fixture.nodes[1]!.children = [10]
        for id in 10..<30 {
            let layer = fixture.add(id, role: "AXGroup", title: "Layer \(id)")
            layer.children = id == 29 ? [2] : [id + 1]
        }
        let before = fixture.render(compact: false)
        let after = fixture.render(compact: true)
        assertAgentTargets(fixture, after, expected: [0, 1, 3, 4])
        XCTAssertEqual(Set(before.records.keys), Set(after.records.keys))
        func depths(_ lines: [String], compact: Bool) -> [Int] {
            lines.map { line in
                var depth = 0
                for char in line.prefix(while: { $0 == " " || $0 == "\t" }) {
                    depth = char == "\t" ? (compact ? (depth / 4 + 1) * 4 : depth + 1) : depth + 1
                }
                return depth
            }
        }
        XCTAssertEqual(depths(before.lines, compact: false), depths(after.lines, compact: true))
        let buttonIndex = fixture.index(3, in: after.records)!
        let linePosition = after.lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(buttonIndex) ") }!
        XCTAssertEqual(depths(after.lines, compact: true)[linePosition], 23)
        for index in before.records.keys {
            let old = before.records[index]!, new = after.records[index]!
            XCTAssertTrue(CFEqual(old.element!, new.element!))
            XCTAssertEqual(old.role, new.role)
            XCTAssertEqual(old.rawActions, new.rawActions)
            XCTAssertEqual(old.localFrame, new.localFrame)
            XCTAssertEqual(old.isSyntheticText, new.isSyntheticText)
        }
    }

    func testCompactTraitNotationRetainsEveryStateAndNativeType() {
        for mask in 0..<8 {
            let states = ["selected", "expanded", "disabled"].enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }
            for type in [nil, "string", "boolean", "float"] as [String?] {
                let raw = states + ["settable"] + (type.map { [$0] } ?? [])
                let compact = AXTreeTextFormatting.traitTokens(raw, compact: true)
                let decoded = compact.flatMap { token -> [String] in
                    switch token {
                    case "w": return ["settable"]
                    case "w:str": return ["settable", "string"]
                    case "w:bool": return ["settable", "boolean"]
                    case "w:float": return ["settable", "float"]
                    default: return [token]
                    }
                }
                XCTAssertEqual(decoded, raw)
            }
        }
        XCTAssertEqual(AXTreeTextFormatting.valueSegment(" Value: a = b (w:str)", compact: true), " = a = b (w:str)")
        for depth in 0...64 {
            let prefix = AXTreeTextFormatting.indentation(depth, compact: true)
            var columns = 0
            for char in prefix { columns = char == "\t" ? (columns / 4 + 1) * 4 : columns + 1 }
            XCTAssertEqual(columns, depth)
        }
    }

    func testOneTabModeKeepsAllOtherCompactionsAndActionRecords() {
        let fixture = Fixture()
        let packed = fixture.render(compact: true, indentation: .tab4)
        let level = fixture.render(compact: true, indentation: .level)
        assertAgentTargets(fixture, packed, expected: [0, 1, 2, 3, 4])
        assertAgentTargets(fixture, level, expected: [0, 1, 2, 3, 4])
        XCTAssertEqual(packed.lines.map { $0.trimmingCharacters(in: .whitespaces) },
                       level.lines.map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(Set(packed.records.keys), Set(level.records.keys))
        for index in packed.records.keys {
            XCTAssertTrue(CFEqual(packed.records[index]!.element!, level.records[index]!.element!))
            XCTAssertEqual(packed.records[index]!.role, level.records[index]!.role)
            XCTAssertEqual(packed.records[index]!.rawActions, level.records[index]!.rawActions)
        }
        for depth in 0...64 {
            XCTAssertEqual(AXTreeTextFormatting.indentation(depth, compact: true, style: .level), String(repeating: "\t", count: depth))
        }
        XCTAssertEqual(AXTreeTextFormatting.legend(for: .level), "[w=settable]")
        XCTAssertEqual(AXTreeTextFormatting.legend(for: .tab4), "[tab=4 w=settable]")
        XCTAssertNil(AXTreeIndentationStyle(rawValue: "invalid"))
    }

    func testRetainedElementHandlesDoNotRetainOldValuesAcrossReads() {
        let fixture = Fixture()
        let before = fixture.render(compact: true)
        fixture.nodes[4]!.attributes["AXValue"] = "updated@example.invalid" as CFString
        let after = withExtendedLifetime(before) { fixture.render(compact: true) }
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
        let output = fixture.render(compact: true)
        assertAgentTargets(fixture, output, expected: [0, 1, 3, 4, 5])
        XCTAssertNotEqual(fixture.index(3, in: output.records), fixture.index(5, in: output.records))
    }
}
