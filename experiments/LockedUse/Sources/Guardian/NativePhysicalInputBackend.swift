import ApplicationServices
import Foundation
import IOKit.hid

/// Independent-device mode prevents the manager from also opening, scheduling
/// or registering value callbacks on devices that we manage individually.
@MainActor
final class NativePhysicalInputBackend: PhysicalInputBackend {
    private var manager: IOHIDManager?
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var opened: Set<UInt64> = []
    private var input: (@MainActor (IOReturn) -> Void)?
    private var topologyChanged: (@MainActor () -> Void)?
    var inputMonitoringAllowed: Bool { CGPreflightListenEventAccess() }

    func start(input: @escaping @MainActor (IOReturn) -> Void,
               topologyChanged: @escaping @MainActor () -> Void) throws -> [MonitoredInputDevice] {
        precondition(manager == nil)
        self.input = input
        self.topologyChanged = topologyChanged
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { pointer, result, _, device in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                let backend = Unmanaged<NativePhysicalInputBackend>.fromOpaque(pointer).takeUnretainedValue()
                // Initial enumeration also generates matching callbacks. Only a
                // genuinely new device invalidates the current inventory.
                if result != kIOReturnSuccess || !backend.devices.values.contains(where: { CFEqual($0, device) }) {
                    backend.topologyChanged?()
                }
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { pointer, _, _, _ in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                Unmanaged<NativePhysicalInputBackend>.fromOpaque(pointer).takeUnretainedValue().topologyChanged?()
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(manager), CFSetGetCount(set) > 0 else {
            throw GuardianError.message("Hardware input inventory unavailable")
        }
        var pointers = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(set))
        CFSetGetValues(set, &pointers)
        var result: [MonitoredInputDevice] = []
        for case let pointer? in pointers {
            let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            let id = UInt64(devices.count + 1)
            devices[id] = device
            var kinds: MonitoredInputKinds = []
            if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) { kinds.insert(.keyboard) }
            if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse))
                || IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) { kinds.insert(.pointer) }
            if IOHIDDeviceConformsTo(device, UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ConsumerControl)) { kinds.insert(.consumer) }
            result.append(MonitoredInputDevice(id: id, kinds: kinds))
        }
        return result
    }

    func open(_ id: UInt64) -> IOReturn {
        guard let device = devices[id] else { return kIOReturnNoDevice }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess { opened.insert(id) }
        return result
    }

    func observe(_ id: UInt64) {
        guard opened.contains(id), let device = devices[id] else { return }
        IOHIDDeviceRegisterInputValueCallback(device, { pointer, result, _, _ in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                Unmanaged<NativePhysicalInputBackend>.fromOpaque(pointer).takeUnretainedValue().input?(result)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func stop() {
        input = nil; topologyChanged = nil
        for id in opened {
            guard let device = devices[id] else { continue }
            // IOKit identifies registrations by context, including removal.
            IOHIDDeviceRegisterInputValueCallback(device, nil, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        opened.removeAll()
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()
        manager = nil
    }
}
