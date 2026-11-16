import AppKit
import Foundation
import OpenComputerUseKit

final class MCPAppRuntime: NSObject, NSApplicationDelegate {
    private let server: StdioMCPServer
    private var runtimeError: Error?
    private var turnEndedObserver: NSObjectProtocol?

    private init(server: StdioMCPServer) {
        self.server = server
    }

    @MainActor
    static func run(server: StdioMCPServer) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let delegate = MCPAppRuntime(server: server)
        application.delegate = delegate
        application.run()

        if let runtimeError = delegate.runtimeError {
            throw runtimeError
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        turnEndedObserver = DistributedNotificationCenter.default().addObserver(
            forName: openComputerUseTurnEndedNotificationName,
            object: nil,
            queue: nil
        ) { _ in
            // Invalidate animations before waiting for main-actor cleanup.
            resetOpenComputerUseVisualCursor()
            Task { @MainActor in
                resetOpenComputerUseBackgroundWindowState()
            }
        }
        Thread.detachNewThreadSelector(#selector(processStandardIO), toTarget: self, with: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        resetOpenComputerUseBackgroundWindowState()
        if let turnEndedObserver {
            DistributedNotificationCenter.default().removeObserver(turnEndedObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc
    private func processStandardIO() {
        do {
            try server.run()
        } catch {
            runtimeError = error
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
