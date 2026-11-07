import XCTest
import IOKit.hid
@testable import OCUGuardian

@MainActor
private final class FakeInputBackend: PhysicalInputBackend {
    var inputMonitoringAllowed = true
    var devices = [MonitoredInputDevice(id: 1, kinds: .keyboard), MonitoredInputDevice(id: 2, kinds: .pointer)]
    var results: [UInt64: IOReturn] = [:]
    var input: (@MainActor (IOReturn) -> Void)?
    var topology: (@MainActor () -> Void)?
    var openIDs: [UInt64] = []
    var observed: [UInt64] = []
    var stops = 0
    var failStart = false
    var changeWhileObserving = false
    func start(input: @escaping @MainActor (IOReturn) -> Void,
               topologyChanged: @escaping @MainActor () -> Void) throws -> [MonitoredInputDevice] {
        self.input = input; topology = topologyChanged
        if failStart { throw GuardianError.message("Injected manager failure") }
        return devices
    }
    func open(_ id: UInt64) -> IOReturn {
        openIDs.append(id)
        return results[id] ?? kIOReturnSuccess
    }
    func observe(_ id: UInt64) {
        observed.append(id)
        if changeWhileObserving { topology?() }
    }
    func stop() { stops += 1 }
}

final class PhysicalInputMonitorTests: XCTestCase {
    func testNormalInputAndIdempotentCleanup() async throws {
        try await MainActor.run {
            let backend = FakeInputBackend()
            var activity = 0, failures = 0
            let monitor = PhysicalInputMonitor(backend: backend, activity: { activity += 1 }, failure: { failures += 1 })
            try monitor.start()
            XCTAssertTrue(monitor.healthy)
            XCTAssertEqual(backend.observed, [1, 2])
            backend.input?(kIOReturnSuccess)
            XCTAssertEqual(activity, 1)
            XCTAssertThrowsError(try monitor.start())
            XCTAssertTrue(monitor.healthy)
            monitor.stop(); monitor.stop()
            backend.input?(kIOReturnSuccess); backend.topology?()
            XCTAssertEqual(backend.stops, 1)
            XCTAssertEqual(activity, 1)
            XCTAssertEqual(failures, 0)
        }
    }

    func testExclusiveKeyboardNeedsReplacementKeyboardNotJustPointer() async throws {
        try await MainActor.run {
            let backend = FakeInputBackend()
            backend.results[1] = kIOReturnExclusiveAccess
            let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: {})
            XCTAssertThrowsError(try monitor.start())
            XCTAssertFalse(monitor.healthy)
            XCTAssertEqual(backend.stops, 1)
            XCTAssertTrue(backend.observed.isEmpty)
            backend.devices.append(MonitoredInputDevice(id: 3, kinds: .keyboard))
            try monitor.start()
            XCTAssertTrue(monitor.healthy)
            XCTAssertEqual(backend.observed, [2, 3])
            monitor.stop()
        }
    }

    func testMissingPointerAndConsumerCategoriesAreRejected() async throws {
        try await MainActor.run {
            for missing: MonitoredInputKinds in [.pointer, .consumer] {
                let backend = FakeInputBackend()
                backend.devices = [.init(id: 1, kinds: .keyboard), .init(id: 2, kinds: missing)]
                backend.results[2] = kIOReturnExclusiveAccess
                let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: {})
                XCTAssertThrowsError(try monitor.start())
                XCTAssertFalse(monitor.healthy)
                XCTAssertEqual(backend.stops, 1)
            }
        }
    }

    func testEmptyUnknownConsumerOnlyAndFullySeizedInventoriesAreRejected() async throws {
        try await MainActor.run {
            for inventory: [MonitoredInputDevice] in [[], [.init(id: 1, kinds: [])], [.init(id: 1, kinds: .consumer)], [.init(id: 1, kinds: .keyboard)]] {
                let backend = FakeInputBackend()
                backend.devices = inventory
                backend.results[1] = kIOReturnExclusiveAccess
                let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: {})
                XCTAssertThrowsError(try monitor.start())
                XCTAssertEqual(backend.stops, 1)
            }
            let backend = FakeInputBackend()
            backend.devices = [.init(id: 1, kinds: .consumer)]
            let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: {})
            XCTAssertThrowsError(try monitor.start())
        }
    }

    func testNonExclusiveErrorsAreNotIgnoredAfterPartialOpen() async throws {
        try await MainActor.run {
            for error in [kIOReturnNotPermitted, kIOReturnNoDevice, kIOReturnError] {
                let backend = FakeInputBackend()
                backend.results[2] = error
                let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: {})
                XCTAssertThrowsError(try monitor.start())
                XCTAssertEqual(backend.openIDs, [1, 2])
                XCTAssertTrue(backend.observed.isEmpty)
                XCTAssertEqual(backend.stops, 1)
            }
        }
    }

    func testPermissionAndManagerFailureCleanup() async throws {
        try await MainActor.run {
            let backend = FakeInputBackend()
            backend.inputMonitoringAllowed = false
            let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: {})
            XCTAssertThrowsError(try monitor.start())
            XCTAssertEqual(backend.stops, 0)
            XCTAssertNil(backend.input)
            backend.inputMonitoringAllowed = true; backend.failStart = true
            XCTAssertThrowsError(try monitor.start())
            XCTAssertEqual(backend.stops, 1)
        }
    }

    func testTopologyAndInputFailuresLatchAndNotifyOnce() async throws {
        try await MainActor.run {
            for topology in [true, false] {
                let backend = FakeInputBackend()
                var failures = 0, activity = 0
                let monitor = PhysicalInputMonitor(backend: backend, activity: { activity += 1 }, failure: { failures += 1 })
                try monitor.start()
                if topology { backend.topology?() } else { backend.input?(kIOReturnNoDevice) }
                XCTAssertFalse(monitor.healthy)
                backend.input?(kIOReturnSuccess); backend.topology?(); backend.input?(kIOReturnError)
                XCTAssertEqual(failures, 1)
                XCTAssertEqual(activity, 0)
                monitor.stop()
                XCTAssertEqual(backend.stops, 1)
            }
        }
    }

    func testTopologyChangeDuringStartupFailsAndCleansUp() async throws {
        try await MainActor.run {
            let backend = FakeInputBackend()
            backend.changeWhileObserving = true
            var failures = 0
            let monitor = PhysicalInputMonitor(backend: backend, activity: {}, failure: { failures += 1 })
            XCTAssertThrowsError(try monitor.start())
            XCTAssertFalse(monitor.healthy)
            XCTAssertEqual(failures, 0)
            XCTAssertEqual(backend.stops, 1)
        }
    }

    func testOldCallbacksCannotAffectRestartedMonitor() async throws {
        try await MainActor.run {
            let backend = FakeInputBackend()
            var failures = 0, activity = 0
            let monitor = PhysicalInputMonitor(backend: backend, activity: { activity += 1 }, failure: { failures += 1 })
            try monitor.start()
            let oldInput = backend.input, oldTopology = backend.topology
            monitor.stop(); try monitor.start()
            oldInput?(kIOReturnSuccess); oldInput?(kIOReturnError); oldTopology?()
            XCTAssertTrue(monitor.healthy)
            XCTAssertEqual(failures, 0)
            XCTAssertEqual(activity, 0)
            backend.input?(kIOReturnSuccess)
            XCTAssertEqual(activity, 1)
            monitor.stop()
        }
    }
}
