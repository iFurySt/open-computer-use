import AppKit
import XCTest
@testable import OpenComputerUseKit

final class TargetedQuerySafetyTests: XCTestCase {
    func testWindowIDValidationRejectsCrashInputsAndWrongTypes() throws {
        XCTAssertNil(try validatedQueryWindowID(nil))
        XCTAssertEqual(try validatedQueryWindowID(1), 1)
        XCTAssertEqual(try validatedQueryWindowID(UInt32.max), UInt32.max)
        for value: Any in [-1, 0, 1.5, Double.infinity, Double.nan, Double(UInt32.max) + 1, true, "1", NSNull()] {
            XCTAssertThrowsError(try validatedQueryWindowID(value), "\(value)")
        }
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(name: "query", arguments: ["app": "NoSuchReviewApp", "text": "Send", "window_id": -1])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("window_id") == true)
    }

    func testQueryStringsAndExactRejectSilentCoercion() throws {
        XCTAssertEqual(try validatedQueryString("Send", key: "text"), "Send")
        XCTAssertThrowsError(try validatedQueryString(3, key: "text"))
        XCTAssertThrowsError(try validatedQueryString(String(repeating: "x", count: 1001), key: "text"))
        XCTAssertTrue(try validatedQueryExact(true))
        XCTAssertFalse(try validatedQueryExact(nil))
        XCTAssertThrowsError(try validatedQueryExact(1))
        XCTAssertThrowsError(try validatedQueryExact("true"))
    }

    func testRegistryRejectsWrongAppAndRestartedProcess() throws {
        let registry = TargetedElementRegistry<String>()
        let original = TargetedAppIdentity(pid: 1, bundleIdentifier: "com.example.A", launchedAt: Date(timeIntervalSince1970: 1))
        let index = registry.insert(app: original) { _ in "control" }
        XCTAssertEqual(try registry.resolve(index, app: original), "control")
        for identity in [TargetedAppIdentity(pid: 2, bundleIdentifier: "com.example.A", launchedAt: original.launchedAt),
                         TargetedAppIdentity(pid: 1, bundleIdentifier: "com.example.B", launchedAt: original.launchedAt),
                         TargetedAppIdentity(pid: 1, bundleIdentifier: "com.example.A", launchedAt: Date(timeIntervalSince1970: 2))] {
            XCTAssertThrowsError(try registry.resolve(index, app: identity))
        }
        XCTAssertEqual(try registry.resolve(index, app: original), "control")
    }

    func testRegistryEvictsExpiresAndDoesNotReuseClearedIndexes() throws {
        var now = Date(timeIntervalSince1970: 0)
        let app = TargetedAppIdentity(pid: 1, bundleIdentifier: nil, launchedAt: nil)
        let registry = TargetedElementRegistry<Int>(capacity: 2, lifetime: 10, now: { now })
        let first = registry.insert(app: app) { $0 }
        let second = registry.insert(app: app) { $0 }
        let third = registry.insert(app: app) { $0 }
        XCTAssertThrowsError(try registry.resolve(first, app: app))
        XCTAssertEqual(try registry.resolve(second, app: app), second)
        registry.remove(second)
        XCTAssertThrowsError(try registry.resolve(second, app: app))
        now = now.addingTimeInterval(10)
        XCTAssertThrowsError(try registry.resolve(third, app: app))
        registry.clear()
        let fourth = registry.insert(app: app) { $0 }
        XCTAssertGreaterThan(fourth, third)
        XCTAssertThrowsError(try registry.resolve(third, app: app))
    }

    func testReadOnlyResolutionNeverLaunchesAbsentApp() {
        XCTAssertThrowsError(try AppDiscovery.resolveRunning("NoSuchReviewApp", applications: []))
        XCTAssertThrowsError(try AppDiscovery.resolveRunning("com.1password.1password", applications: []))
    }

    func testWideTreeBoundsChildFetchAndReportsPartialMatches() throws {
        var fetched = 0
        let result = try boundedTargetedWalk(root: 0, maxNodes: 3, limit: 10, expired: { false }, inspect: { node in
            (node > 0, node == 0)
        }, children: { _, remaining in
            fetched = remaining
            return (Array(1...remaining), true)
        })
        XCTAssertEqual(fetched, 2)
        XCTAssertEqual(result.visitedNodes, 3)
        XCTAssertEqual(result.matches, [1, 2])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stopReason, "max_nodes")
    }

    func testTraversalDeduplicatesCyclesAndStopsAtResultLimit() throws {
        let cycle = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { _ in (true, true) }, children: { node, _ in
            ([node, (node + 1) % 2], false)
        })
        XCTAssertEqual(cycle.matches, [0, 1])
        XCTAssertFalse(cycle.truncated)
        let limited = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 1, expired: { false }, inspect: { _ in (true, true) }, children: { _, _ in XCTFail("should not fetch children"); return ([], false) })
        XCTAssertEqual(limited.stopReason, "limit")
    }

    func testSlowChildFetchReportsTimeoutRatherThanNodeLimit() throws {
        var expired = false
        let result = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { expired },
                                            inspect: { _ in (true, true) }, children: { _, _ in
            expired = true
            return ([], true)
        })
        XCTAssertEqual(result.matches, [0])
        XCTAssertEqual(result.stopReason, "timeout")
    }

    func testExactDoesNotMatchTruncatedLongLabel() {
        let criteria = TargetedAX.Criteria(text: String(repeating: "x", count: 1000), exact: true, role: nil, limit: 20, maxNodes: 500)
        XCTAssertFalse(targetedRecordMatches(criteria, role: "AXButton", title: String(repeating: "x", count: 1001), description: nil, value: nil))
    }

    func testTraversalReportsTimeoutAndAXErrors() throws {
        let timedOut = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { true }, inspect: { _ in XCTFail("should not inspect"); return (false, true) }, children: { _, _ in ([], false) })
        XCTAssertEqual(timedOut.visitedNodes, 0)
        XCTAssertEqual(timedOut.stopReason, "timeout")
        let failed = try boundedTargetedWalk(root: 0, maxNodes: 10, limit: 10, expired: { false }, inspect: { node in
            if node == 1 { throw ComputerUseError.stateUnavailable("unreadable") }
            return (true, true)
        }, children: { _, _ in ([1], false) })
        XCTAssertEqual(failed.matches, [0])
        XCTAssertEqual(failed.stopReason, "ax_error")
    }

    func testSettleMsRejectsAnythingButAPositiveInteger() {
        let dispatcher = ComputerUseToolDispatcher()
        for value: Any in [0, -1, 1.5, true, "300"] {
            let result = dispatcher.callToolAsResult(name: "get_app_state", arguments: ["app": "NoSuchReviewApp", "settle_ms": value])
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.primaryText?.contains("settle_ms") == true, "\(value)")
        }
    }

    func testSettleWaitLooksAgainWhileBusyAndHoldsTheCeiling() {
        // A fake clock: sleeping advances it, and every look costs 7 ms.
        var clock = 0.0
        var looks: [Double] = []
        func wait(timeout: Double = 5, busy: @escaping (Double) -> Bool) -> Bool {
            clock = 0
            looks = []
            return WindowSettle.wait(timeout: timeout, now: { clock }, sleep: { clock += $0 }) {
                looks.append(clock)
                defer { clock += 0.007 }
                return busy(clock)
            }
        }

        // Showing no busy sign: one look, no wait.
        XCTAssertTrue(wait { _ in false })
        XCTAssertEqual(looks, [0])

        // Loading until 0.3 s: looked at again every 50 ms, read on the first look after it ends.
        XCTAssertTrue(wait { $0 < 0.3 })
        XCTAssertEqual(looks.count, 7)
        XCTAssertLessThan(clock, 0.36)

        // Never done: gives up at the ceiling, and no look starts past it.
        XCTAssertFalse(wait(timeout: 1) { _ in true })
        XCTAssertLessThanOrEqual(looks.max() ?? 0, 1)
        XCTAssertLessThan(clock, 1.01)
    }

    func testBusyScanReadsALevelAtOnceAndAnswersAsTheNodeByNodeWalk() {
        typealias Signs = WindowSettle.Signs<Int>
        // The walk as it would be one node at a time: breadth first, same caps, same signs.
        func oneByOne(_ tree: [Int: Signs]) -> (Bool, [Int]) {
            var nodes = [(0, 0)], visited: [Int] = [], next = 0
            while next < nodes.count {
                let (id, depth) = nodes[next]; next += 1; visited.append(id)
                guard let node = tree[id] else { continue }
                if node.role == "AXBusyIndicator" || (node.role == "AXWebArea" && node.loaded == false) || node.busy == true { return (true, visited) }
                if depth < WindowSettle.scanDepth { nodes += node.children.prefix(max(0, WindowSettle.scanNodes - nodes.count)).map { ($0, depth + 1) } }
            }
            return (false, visited)
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var tree: [Int: Signs] = [:], parents = [0], nextID = 1
            for _ in 0..<Int.random(in: 1...160, using: &generator) {
                let parent = parents.randomElement(using: &generator)!
                tree[parent] = Signs(role: tree[parent]?.role, children: (tree[parent]?.children ?? []) + [nextID], busy: tree[parent]?.busy, loaded: tree[parent]?.loaded)
                let roll = Int.random(in: 0..<400, using: &generator)
                tree[nextID] = Signs(role: roll == 0 ? "AXBusyIndicator" : roll == 1 ? "AXWebArea" : roll < 4 ? nil : "AXGroup",
                                     children: [], busy: roll == 2 ? true : nil, loaded: roll == 1 ? false : roll == 5 ? true : nil)
                if roll == 3 { tree[nextID] = nil }
                parents.append(nextID); nextID += 1
            }
            var batched: [Int] = []
            var reads = 0
            let answer = WindowSettle.busy(from: 0) { ids in reads += 1; batched += ids; return ids.map { tree[$0] } }
            let expected = oneByOne(tree)
            XCTAssertEqual(answer, expected.0)
            // Every node the node-by-node walk visits is read, in the same order; a batch may read the rest of a level past a busy node.
            XCTAssertEqual(Array(batched.prefix(expected.1.count)), expected.1)
            XCTAssertLessThanOrEqual(reads, WindowSettle.scanDepth + 1)
        }
    }
}
