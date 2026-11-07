// Compiled with the production DisplayShieldSurface, appearance and geometry.
// The runner adds observation calls without changing placement or health checks.
import AppKit

enum GuardianError: Error { case message(String) }

@MainActor
enum PlacementEvidence {
    static var samples: [[String: Any]] = []
    static func rect(_ value: CGRect) -> [Double] {
        [value.origin.x, value.origin.y, value.width, value.height]
    }
    static func record(_ window: NSWindow, screen: NSScreen, stage: String) {
        let expected = LockedUseShieldCoverage.surfaceFrame(for: screen.frame)
        let actual = window.frame
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        // AppKit rounds fractional-point borders; a screen-origin-sized offset is not rounding.
        let aligned = abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1
            && abs(actual.width - expected.width) <= 1 && abs(actual.height - expected.height) <= 1
        samples.append(["stage": stage, "screen": rect(screen.frame), "quartz": rect(CGDisplayBounds(id)),
                        "scale": screen.backingScaleFactor, "expected": rect(expected), "actual": rect(actual),
                        "aligned": aligned])
    }
}

@main
struct ShieldPlacementFixture {
    @MainActor static func settle(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: min(until, Date(timeIntervalSinceNow: 0.02))) }
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if CommandLine.arguments.contains("--inventory") {
            let inventory = NSScreen.screens.map { screen -> [String: Any] in
                let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
                return ["id": id, "cocoa": PlacementEvidence.rect(screen.frame),
                        "quartz": PlacementEvidence.rect(CGDisplayBounds(id)), "scale": screen.backingScaleFactor]
            }.sorted { ($0["id"] as! UInt32) < ($1["id"] as! UInt32) }
            print(String(data: try! JSONSerialization.data(withJSONObject: inventory, options: .sortedKeys), encoding: .utf8)!)
            return
        }
        var handle: UnsafeMutableRawPointer?
        let surface = DisplayShieldSurface()
        var exitCode: Int32 = 0
        do {
            if CommandLine.arguments.contains("--virtual-display") {
                let id = ocu_virtual_display_create("OCU Shield Placement Test", 1920, 1080, 60, &handle)
                guard id != 0, handle != nil else { throw GuardianError.message("Cannot create virtual display") }
                settle(1)
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                    throw GuardianError.message("Cannot begin virtual display placement")
                }
                let width = Int32(CGDisplayBounds(id).width)
                guard width > 0, CGConfigureDisplayOrigin(config, id, -width, 0) == .success else {
                    CGCancelDisplayConfiguration(config)
                    throw GuardianError.message("Cannot place test virtual display")
                }
                guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
                    throw GuardianError.message("Cannot apply test virtual display placement")
                }
                settle(1)
            }
            guard NSScreen.screens.count >= 2 else { throw GuardianError.message("At least two screens required") }
            try surface.coverDisplays(message: "OCU shield placement test — closes automatically")
            defer { surface.close() }
            // Exercise the same strict WindowServer geometry/owner/opacity/layer checks.
            let deadline = Date(timeIntervalSinceNow: 3)
            while surface.coverageFailure() != nil && Date() < deadline { settle(0.05) }
            var failures: [String] = []
            for _ in 0..<10 {
                if let failure = surface.coverageFailure() { failures.append(failure) }
                settle(0.05)
            }
            let result: [String: Any] = ["samples": PlacementEvidence.samples, "coverageFailures": failures,
                                        "displayCount": surface.count, "virtualDisplay": handle != nil,
                                        "lockRequested": false, "unlockRequested": false]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
            guard failures.isEmpty else { throw GuardianError.message("Production coverage check failed") }
        } catch {
            fputs("Shield placement test: \(error)\n", stderr)
            exitCode = 1
        }
        surface.close()
        if let handle { ocu_virtual_display_destroy(handle); settle(1) }
        // WindowServer/AppKit may retain the virtual display until this process exits.
        // The runner verifies the original display inventory in a fresh process.
        exit(exitCode)
    }
}
