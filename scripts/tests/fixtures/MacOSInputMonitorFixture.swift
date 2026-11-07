import AppKit
import Carbon
import Foundation
import IOKit.hid

enum GuardianError: Error { case message(String) }

@MainActor
final class EventCounts {
    var pointer = 0
    var keyboard = 0
    var disabled = 0
}

@main
struct InputMonitorFixture {
    @MainActor static func emit(_ values: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        FileHandle.standardOutput.write(data + Data([10]))
    }
    @MainActor static func settle(_ seconds: Double, tick: (() -> Void)? = nil) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: min(deadline, Date(timeIntervalSinceNow: 0.02)), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            tick?()
            NSApp.updateWindows()
        }
    }
    @MainActor static func main() {
        let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5
        guard seconds >= 1, seconds <= 60 else { exit(64) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let events = EventCounts()
        let mask = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
                    .keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { pointer, type, event, context in
                if let context {
                    MainActor.assumeIsolated {
                        let counts = Unmanaged<EventCounts>.fromOpaque(context).takeUnretainedValue()
                        switch type {
                        case .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel: counts.pointer += 1
                        case .keyDown, .keyUp, .flagsChanged: counts.keyboard += 1
                        case .tapDisabledByTimeout, .tapDisabledByUserInput: counts.disabled += 1
                        default: break
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(events).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            emit(["event": "failed", "error": "Read-only comparison event tap unavailable"])
            exit(1)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        defer {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            withExtendedLifetime(events) {}
        }
        var activity = 0, failures = 0
        let monitor = PhysicalInputMonitor(activity: { activity += 1 }, failure: { failures += 1 })
        do {
            try monitor.start()
            emit(["event": "started", "healthy": monitor.healthy, "seconds": seconds,
                  "lockRequested": false, "readsInputValues": false,
                  "secureInput": IsSecureEventInputEnabled()])
            let label = NSTextField(wrappingLabelWithString: "")
            let panel: NSPanel? = CommandLine.arguments.contains("--panel") ? NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false) : nil
            if let panel {
                panel.title = "OCU 输入监控测试"
                panel.isReleasedWhenClosed = false
                panel.level = .floating
                label.frame = NSRect(x: 20, y: 20, width: 400, height: 110)
                label.font = .systemFont(ofSize: 16)
                panel.contentView?.addSubview(label)
                panel.center()
                panel.orderFrontRegardless()
            }
            defer { panel?.close() }
            let began = ProcessInfo.processInfo.systemUptime
            var activePointerSamples = 0
            var minimumPointerIdle = Double.greatestFiniteMagnitude
            settle(seconds) {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let idle = [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel].map {
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
                }.min()!
                if elapsed > 3 {
                    minimumPointerIdle = min(minimumPointerIdle, idle)
                    if idle < 0.25 { activePointerSamples += 1 }
                }
                label.stringValue = "请移动鼠标 / 触控板并轻点，不要按键。\n剩余 \(max(0, Int(ceil(seconds - elapsed)))) 秒\nHID 活动：\(activity)；系统鼠标事件：\(events.pointer)\n仅统计次数，不记录位置或按键内容。"
            }
            panel?.orderOut(nil)
            let healthy = monitor.healthy
            monitor.stop()
            let countAtStop = activity
            settle(0.2)
            guard healthy, failures == 0, activity == countAtStop else {
                throw GuardianError.message("Monitoring failed or callback survived stop")
            }
            // Re-open the actual devices after cleanup and confirm that initial
            // enumeration notifications don't look like a topology change.
            try monitor.start()
            settle(0.5)
            let restarted = monitor.healthy
            monitor.stop()
            emit(["event": "completed", "healthy": healthy, "activityCallbacks": countAtStop,
                  "failures": failures, "restartHealthy": restarted, "healthyAfterStop": monitor.healthy,
                  "systemPointerEvents": events.pointer, "systemKeyboardEvents": events.keyboard,
                  "comparisonTapDisabled": events.disabled,
                  "pointerRecentlyActiveSamples": activePointerSamples,
                  "minimumPointerIdleSeconds": minimumPointerIdle])
            guard restarted, failures == 0 else { throw GuardianError.message("Restart failed") }
        } catch {
            monitor.stop()
            emit(["event": "failed", "error": String(describing: error)])
            exit(1)
        }
    }
}
