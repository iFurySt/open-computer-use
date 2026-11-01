import ApplicationServices
import Foundation
import IOKit.hid

/// Supplement the filtering CG tap with hardware activity detection. No HID
/// values, key usages, text, device names or serial numbers are read or logged.
/// Secure Event Input delivery must be validated on the target OS before the
/// Broker's production validation stamp may be written.
@MainActor
final class PhysicalInputMonitor {
    private var manager: IOHIDManager?
    private var directlyOpenedDevices: [IOHIDDevice] = []
    private let activity: @MainActor () -> Void
    private let failure: @MainActor () -> Void
    private(set) var healthy = false

    init(activity: @escaping @MainActor () -> Void, failure: @escaping @MainActor () -> Void) {
        self.activity = activity; self.failure = failure
    }

    func start() throws {
        guard CGPreflightListenEventAccess() else { throw GuardianError.message("Input Monitoring missing") }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { pointer, result, _, _ in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                let observer = Unmanaged<PhysicalInputMonitor>.fromOpaque(pointer).takeUnretainedValue()
                if result == kIOReturnSuccess { observer.activity() }
                else { observer.healthy = false; observer.failure() }
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { pointer, _, _, _ in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                let observer = Unmanaged<PhysicalInputMonitor>.fromOpaque(pointer).takeUnretainedValue()
                observer.healthy = false; observer.failure()
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 else {
            stop(); throw GuardianError.message("Hardware input activity monitor unavailable")
        }
        if openResult != kIOReturnSuccess {
            // Another process (for example Karabiner-Elements) can seize some
            // keyboards exclusively, which makes the all-or-nothing manager open
            // fail with kIOReturnExclusiveAccess. Fall back to per-device opens and
            // continue when at least one input source stays observable (the seizing
            // tool normally re-emits the keys through a virtual keyboard).
            guard openResult == kIOReturnExclusiveAccess,
                  openDevicesIndividually(devices, context: context) > 0 else {
                stop(); throw GuardianError.message("Hardware input activity monitor unavailable")
            }
        }
        healthy = true
    }

    /// Opens every device on its own and returns how many are observable.
    private func openDevicesIndividually(_ devices: CFSet, context: UnsafeMutableRawPointer) -> Int {
        let count = CFSetGetCount(devices)
        var pointers = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &pointers)
        var opened: [IOHIDDevice] = []
        for case let pointer? in pointers {
            let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            IOHIDDeviceRegisterInputValueCallback(device, { pointer, result, _, _ in
                guard let pointer else { return }
                MainActor.assumeIsolated {
                    let observer = Unmanaged<PhysicalInputMonitor>.fromOpaque(pointer).takeUnretainedValue()
                    if result == kIOReturnSuccess { observer.activity() }
                    else { observer.healthy = false; observer.failure() }
                }
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            opened.append(device)
        }
        directlyOpenedDevices = opened
        return opened.count
    }

    func stop() {
        healthy = false
        for device in directlyOpenedDevices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        directlyOpenedDevices = []
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }
}
