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

    func testStableDigestWaitSettlesAfterChangesStopAndHoldsTheCeiling() {
        // A fake clock: sleeping advances it, and every digest read costs 20 ms.
        var clock = 0.0
        var polls: [Double] = []
        func wait(quiet: Double, timeout: Double = 5, digest: @escaping (Double) -> Int) -> Bool {
            clock = 0
            polls = []
            return waitForStableDigest(quiet: quiet, timeout: timeout, now: { clock }, sleep: { clock += $0 }) {
                polls.append(clock)
                defer { clock += 0.02 }
                return digest(clock)
            }
        }

        // Already still: costs the quiet period plus the first read.
        XCTAssertTrue(wait(quiet: 0.3) { _ in 7 })
        XCTAssertEqual(clock, 0.32, accuracy: 0.03)

        // Loading until 2 s: settles one quiet period after the last change.
        XCTAssertTrue(wait(quiet: 0.3) { t in t < 2 ? Int(t * 20) : -1 })
        XCTAssertGreaterThanOrEqual(clock, 2.3)
        XCTAssertLessThan(clock, 2.5)

        // A blip restarts the quiet period from the read that sees it end (at 0.36 s).
        XCTAssertTrue(wait(quiet: 0.3) { t in (0.2..<0.3).contains(t) ? 1 : 0 })
        XCTAssertGreaterThanOrEqual(clock, 0.66)
        XCTAssertLessThan(clock, 0.8)

        // Never still: gives up at the ceiling, and no read starts past it.
        var tick = 0
        XCTAssertFalse(wait(quiet: 0.3, timeout: 5) { _ in tick += 1; return tick })
        XCTAssertLessThanOrEqual(polls.max() ?? 0, 5)
        XCTAssertLessThan(clock, 5.1)

        // A quiet period longer than the ceiling cannot be met.
        XCTAssertFalse(wait(quiet: 2, timeout: 1) { _ in 7 })
        XCTAssertLessThanOrEqual(clock, 1.05)
    }
}
