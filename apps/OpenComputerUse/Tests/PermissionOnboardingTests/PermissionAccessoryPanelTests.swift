import AppKit
import XCTest
@testable import OpenComputerUse
@testable import OpenComputerUseKit

final class PermissionAccessoryPanelTests: XCTestCase {
    func testInterruptedLaunchRestoresFullPanel() async throws {
        try await MainActor.run {
            for elapsed in [0.0, 0.05, 0.18, 0.4, 0.7] {
                let fixture = Fixture()
                defer { fixture.close() }
                fixture.controller.show(for: .accessibility, sourceFrameInScreen: fixture.sourceFrame)
                fixture.time = elapsed
                fixture.controller.stepLaunchAnimation()
                fixture.settingsVisible = false
                fixture.controller.refresh()
                XCTAssertFalse(fixture.panel.isVisible)
                fixture.settingsVisible = true
                fixture.controller.refresh()
                try fixture.capture("interrupted-\(elapsed)")
                fixture.assertFullPanel()
            }
        }
    }

    func testCompletedLaunchUsesExactTargetSize() async throws {
        try await MainActor.run {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.controller.show(for: .accessibility, sourceFrameInScreen: fixture.sourceFrame)
            fixture.time = 0.7
            fixture.controller.stepLaunchAnimation()
            fixture.time = 0.73
            fixture.controller.stepLaunchAnimation()
            fixture.assertFullPanel()
            try fixture.capture("completed")
        }
    }

    func testNewGuidanceAfterInterruptedLaunchUsesFullPanel() async throws {
        try await MainActor.run {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.controller.show(for: .accessibility, sourceFrameInScreen: fixture.sourceFrame)
            fixture.time = 0.18
            fixture.controller.stepLaunchAnimation()
            fixture.controller.hide()
            fixture.controller.show(for: .screenRecording, sourceFrameInScreen: nil)
            fixture.assertFullPanel()
            try fixture.capture("new-guidance")
        }
    }

    func testPanelAnchorsBelowPermissionListAndFitsItsWidth() async throws {
        try await MainActor.run {
            let fixture = Fixture()
            defer { fixture.close() }
            let list = CGRect(x: 380, y: 650, width: 460, height: 250)
            fixture.permissionListFrame = list
            fixture.controller.show(for: .screenRecording, sourceFrameInScreen: nil)
            XCTAssertEqual(fixture.panel.frame.maxY, list.minY - 8, accuracy: 0.01)
            XCTAssertEqual(fixture.panel.frame.midX, list.midX, accuracy: 0.01)
            fixture.assertFullPanel(expectedWidth: 460)
        }
    }

    func testMovingListUpdatesAnimationTargetAndInterruptedRecovery() async throws {
        try await MainActor.run {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.permissionListFrame = CGRect(x: 380, y: 650, width: 560, height: 250)
            fixture.controller.show(for: .accessibility, sourceFrameInScreen: fixture.sourceFrame)
            fixture.time = 0.18
            fixture.controller.stepLaunchAnimation()
            let moved = CGRect(x: 400, y: 600, width: 460, height: 250)
            fixture.permissionListFrame = moved
            fixture.controller.refresh()
            fixture.time = 0.73
            fixture.controller.stepLaunchAnimation()
            XCTAssertEqual(fixture.panel.frame.maxY, moved.minY - 8, accuracy: 0.01)
            XCTAssertEqual(fixture.panel.frame.midX, moved.midX, accuracy: 0.01)
            fixture.settingsVisible = false
            fixture.controller.refresh()
            fixture.settingsVisible = true
            fixture.controller.refresh()
            fixture.assertFullPanel(expectedWidth: 460)
        }
    }

    func testMissingListGeometryKeepsWindowFallback() async throws {
        await MainActor.run {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.controller.show(for: .accessibility, sourceFrameInScreen: nil)
            XCTAssertEqual(fixture.panel.frame.maxY, fixture.referenceWindow.frame.minY + 6, accuracy: 0.01)
        }
    }

    func testListDiscoveryAndLossSwitchBetweenListAndWindowEdges() async throws {
        await MainActor.run {
            let fixture = Fixture()
            defer { fixture.close() }
            fixture.controller.show(for: .screenRecording, sourceFrameInScreen: nil)
            let fallback = fixture.panel.frame
            fixture.permissionListFrame = CGRect(x: 380, y: 650, width: 460, height: 250)
            fixture.controller.refresh()
            XCTAssertEqual(fixture.panel.frame.maxY, 642, accuracy: 0.01)
            fixture.assertFullPanel(expectedWidth: 460)
            fixture.permissionListFrame = nil
            fixture.controller.refresh()
            XCTAssertEqual(fixture.panel.frame, fallback)
            fixture.assertFullPanel()
        }
    }

    @MainActor
    private final class Fixture {
        var time: CFTimeInterval = 0
        var settingsVisible = true
        var permissionListFrame: CGRect?
        let sourceFrame = CGRect(x: 500, y: 500, width: 104, height: 44)
        let referenceWindow: NSWindow
        let existingWindows: Set<ObjectIdentifier>
        lazy var controller = PermissionAccessoryPanelController(
            onBack: {},
            windowContextProvider: { [unowned self] in
                settingsVisible ? .init(bounds: referenceWindow.frame, windowNumber: referenceWindow.windowNumber,
                                        permissionListFrame: permissionListFrame) : nil
            },
            animationTimeProvider: { [unowned self] in time }
        )
        var panel: NSWindow {
            NSApp.windows.first {
                $0.contentView is PermissionAccessoryPanelView && !existingWindows.contains(ObjectIdentifier($0))
            }!
        }

        init() {
            _ = NSApplication.shared
            existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            referenceWindow = NSWindow(contentRect: NSRect(x: 100, y: 300, width: 850, height: 700),
                                       styleMask: [], backing: .buffered, defer: false)
            referenceWindow.isReleasedWhenClosed = false
        }

        func close() {
            controller.hide()
            panel.close()
            referenceWindow.close()
        }

        func assertFullPanel(expectedWidth: CGFloat = 530, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(panel.isVisible, file: file, line: line)
            XCTAssertEqual(panel.frame.width, expectedWidth, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(panel.frame.height, 109, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001, file: file, line: line)
            let content = panel.contentView!
            content.layoutSubtreeIfNeeded()
            for view in descendants(of: content) where view is DraggableAppTileView || view is NSButton || view is NSTextField {
                let rect = view.convert(view.bounds, to: content)
                XCTAssertTrue(content.bounds.contains(rect), "\(type(of: view)) outside panel: \(rect)", file: file, line: line)
                if let label = view as? NSTextField, let cell = label.cell {
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000))
                    XCTAssertLessThanOrEqual(needed.height, label.bounds.height + 1, label.stringValue, file: file, line: line)
                }
            }
        }

        func capture(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["OCU_TEST_SNAPSHOT_DIRECTORY"] else { return }
            let content = panel.contentView!
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("guidance-\(name).png"))
        }

        private func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
    }
}
