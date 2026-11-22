import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class KeySequenceTests: XCTestCase {
    private func steps(_ json: String) throws -> [KeySequenceStep] {
        try KeySequence.parse(JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    /// (keyCode, down, flags) for each posted key event; waits are dropped.
    private func keys(_ timeline: [KeySequenceStep]) throws -> [(CGKeyCode, Bool, CGEventFlags)] {
        KeySequence.actions(for: try KeySequence.resolve(timeline)).compactMap { action in
            if case let .key(keyCode, down, flags) = action { return (keyCode, down, flags) }
            return nil
        }
    }

    func testWalkAndJumpHoldsWAroundTheSpaceTap() throws {
        let parsed = try steps(#"[{"down":"w"},{"wait_ms":300},{"press":"space"},{"wait_ms":700},{"up":"w"}]"#)
        XCTAssertEqual(parsed, [.down("w"), .wait(milliseconds: 300), .press("space"), .wait(milliseconds: 700), .up("w")])

        let events = try keys(parsed)
        let w = CGKeyCode(kVK_ANSI_W), space = CGKeyCode(kVK_Space)
        XCTAssertEqual(events.map(\.0), [w, space, space, w])
        XCTAssertEqual(events.map(\.1), [true, true, false, false], "W stays down across the Space tap")

        let waits = KeySequence.actions(for: try KeySequence.resolve(parsed)).compactMap { action -> TimeInterval? in
            if case let .wait(seconds) = action { return seconds }
            return nil
        }
        XCTAssertEqual(waits, [0.3, 0.7])
    }

    func testHeldModifiersApplyToLaterEventsAndHeldKeysAreReleasedAtTheEnd() throws {
        let events = try keys([.down("shift"), .down("d"), .press("a")])
        XCTAssertTrue(events.dropFirst().allSatisfy { $0.2.contains(.maskShift) || !$0.1 && $0.0 == CGKeyCode(kVK_Shift) },
                      "events sent while shift is held carry the shift flag")
        let releases = events.suffix(2)
        XCTAssertEqual(releases.map(\.0), [CGKeyCode(kVK_ANSI_D), CGKeyCode(kVK_Shift)], "still-held keys are released, last pressed first")
        XCTAssertTrue(releases.allSatisfy { !$0.1 })
        XCTAssertFalse(events.last!.2.contains(.maskShift), "the shift release clears the flag")
    }

    func testChordPressAddsItsModifierOnlyForTheChord() throws {
        let events = try keys([.press("cmd+a"), .press("b")])
        let b = events.first { $0.0 == CGKeyCode(kVK_ANSI_B) }
        XCTAssertNotNil(b)
        XCTAssertFalse(b!.2.contains(.maskCommand))
        XCTAssertEqual(events.filter { $0.0 == CGKeyCode(kVK_Command) }.map(\.1), [true, false])
    }

    func testBadTimelinesFailBeforeAnythingIsSent() {
        let bad: [[KeySequenceStep]] = [
            [],
            [.up("w")],
            [.down("w"), .down("W")],
            [.down("w+space")],
            [.press("nosuchkey")],
            [.wait(milliseconds: 5_001)],
            [.wait(milliseconds: 5_000), .wait(milliseconds: 5_000), .wait(milliseconds: 1)],
            Array(repeating: .press("a"), count: KeySequence.maximumSteps + 1),
        ]
        for timeline in bad {
            XCTAssertThrowsError(try KeySequence.resolve(timeline), "\(timeline.prefix(3))")
        }
    }

    func testStepObjectsNeedExactlyOneKnownActionAndWholeMilliseconds() throws {
        for json in [
            #"{"down":"w"}"#,
            #"[{"down":"w","up":"w"}]"#,
            #"[{"hold":"w"}]"#,
            #"[{"down":""}]"#,
            #"[{"wait_ms":-1}]"#,
            #"[{"wait_ms":"300"}]"#,
            #"[{"wait_ms":true}]"#,
            #"[{"wait_ms":1.5}]"#,
            #"[{"wait_ms":null}]"#,
        ] {
            XCTAssertThrowsError(try steps(json), json)
        }
        XCTAssertEqual(try steps(#"[{"wait_ms":80.0},{"wait_ms":0}]"#), [.wait(milliseconds: 80), .wait(milliseconds: 0)])
    }

    func testToolSchemaListsTheFourActions() throws {
        let tool = try XCTUnwrap(ToolDefinitions.all.first { $0.name == "key_sequence" })
        let properties = try XCTUnwrap(tool.inputSchema["properties"] as? [String: Any])
        let items = try XCTUnwrap((properties["steps"] as? [String: Any])?["items"] as? [String: Any])
        let stepProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        XCTAssertEqual(Set(stepProperties.keys), ["down", "up", "press", "wait_ms"])
        XCTAssertEqual((stepProperties["wait_ms"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual(tool.inputSchema["required"] as? [String], ["app", "steps"])
    }
}
