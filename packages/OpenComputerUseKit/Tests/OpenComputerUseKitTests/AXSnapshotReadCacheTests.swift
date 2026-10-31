import ApplicationServices
import XCTest
@testable import OpenComputerUseKit

final class AXSnapshotReadCacheTests: XCTestCase {
    func testEqualAXReferencesShareTheBatchAndAbsentValuesDoNotRefetch() {
        var batches = 0, singles = 0
        let cache = AXSnapshotReadCache(batch: { _ in
            batches += 1
            return ["AXRole": .value("AXButton" as CFString), "AXHelp": .absent]
        }, single: { _, _ in singles += 1; return (.attributeUnsupported, nil) })
        let first = AXUIElementCreateApplication(123)
        let equalReference = AXUIElementCreateApplication(123)
        XCTAssertEqual(cache.value(first, "AXRole") as? String, "AXButton")
        XCTAssertEqual(cache.value(equalReference, "AXRole") as? String, "AXButton")
        XCTAssertNil(cache.value(first, "AXHelp"))
        XCTAssertNil(cache.value(equalReference, "AXHelp"))
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(singles, 0)
    }

    func testUnavailableBatchFallsBackAndDoesNotCacheTransientFailure() {
        var singles = 0
        let cache = AXSnapshotReadCache(batch: { _ in [:] }, single: { _, _ in
            singles += 1
            return singles == 1 ? (.cannotComplete, nil) : (.success, "fresh" as CFString)
        })
        let element = AXUIElementCreateApplication(123)
        XCTAssertNil(cache.value(element, "AXTitle"))
        XCTAssertEqual(cache.value(element, "AXTitle") as? String, "fresh")
        XCTAssertEqual(cache.value(element, "AXTitle") as? String, "fresh")
        XCTAssertEqual(singles, 2)
    }

    func testEachSnapshotHasFreshStorageAndRestoresOuterScopeOnFailure() {
        enum Probe: Error { case stop }
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[AXSnapshotReadCache.key]
        defer { dictionary[AXSnapshotReadCache.key] = previous }
        let outer = AXSnapshotReadCache(batch: { _ in [:] })
        dictionary[AXSnapshotReadCache.key] = outer
        var first: AXSnapshotReadCache?
        AXSnapshotReadCache.withSnapshot { first = AXSnapshotReadCache.current }
        XCTAssertTrue(AXSnapshotReadCache.current === outer)
        XCTAssertThrowsError(try AXSnapshotReadCache.withSnapshot {
            XCTAssertFalse(AXSnapshotReadCache.current === first)
            throw Probe.stop
        })
        XCTAssertTrue(AXSnapshotReadCache.current === outer)
    }
    func testOnlyAnonymousActionTargetsNeedRenderedFrames() {
        XCTAssertTrue(shouldRenderActionTargetFrame(title: nil, label: nil, value: nil, summary: nil, placeholder: nil))
        XCTAssertFalse(shouldRenderActionTargetFrame(title: "Play", label: nil, value: nil, summary: nil, placeholder: nil))
        XCTAssertFalse(shouldRenderActionTargetFrame(title: nil, label: nil, value: nil, summary: "Open details", placeholder: nil))
        XCTAssertFalse(shouldRenderActionTargetFrame(title: nil, label: nil, value: "off", summary: nil, placeholder: nil))
    }

}
