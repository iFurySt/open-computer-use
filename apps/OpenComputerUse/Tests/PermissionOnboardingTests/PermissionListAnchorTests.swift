import AppKit
import ApplicationServices
import XCTest
@testable import OpenComputerUse

final class PermissionListAnchorTests: XCTestCase {
    private final class Node {
        let role: String
        let children: [Node]
        init(_ role: String, _ children: [Node] = []) { self.role = role; self.children = children }
    }

    func testTwoListsChooseUpperControlsWithoutReadingAppRows() {
        let apps = Node(kAXListRole, (0..<1000).map { _ in Node(kAXRowRole) })
        let upper = Node(kAXGroupRole, [Node(kAXScrollAreaRole, [apps]), Node(kAXButtonRole), Node(kAXButtonRole)])
        let lower = Node(kAXGroupRole, [Node(kAXScrollAreaRole, [apps]), Node(kAXButtonRole), Node(kAXButtonRole)])
        let sidebar = Node(kAXScrollAreaRole, [Node(kAXListRole, [Node(kAXRowRole)])])
        let root = Node(kAXWindowRole, [Node(kAXGroupRole, [sidebar, Node(kAXScrollAreaRole, [upper, lower])])])
        var reads = 0
        let match = PermissionListAnchorSearch.first(in: root, role: { $0.role }, children: {
            reads += 1
            XCTAssertNotEqual($0.role, kAXListRole)
            XCTAssertNotEqual($0.role, kAXRowRole)
            return $0.children
        })
        XCTAssertTrue(match?.container === upper)
        XCTAssertLessThan(reads, 10)
    }

    func testNavigationButtonsDoNotMatchListControls() {
        let toolbar = Node(kAXGroupRole, [Node(kAXButtonRole), Node(kAXButtonRole)])
        let root = Node(kAXWindowRole, [toolbar, Node(kAXScrollAreaRole, [Node(kAXListRole)])])
        XCTAssertNil(PermissionListAnchorSearch.first(in: root, role: { $0.role }, children: { $0.children }))
    }

    func testNestedUpperListStillPrecedesShallowerLowerList() {
        let upper = Node(kAXGroupRole, [Node(kAXListRole), Node(kAXButtonRole), Node(kAXButtonRole)])
        let lower = Node(kAXGroupRole, [Node(kAXListRole), Node(kAXButtonRole), Node(kAXButtonRole)])
        let root = Node(kAXWindowRole, [Node(kAXGroupRole, [Node(kAXGroupRole, [upper]), lower])])
        let match = PermissionListAnchorSearch.first(in: root, role: { $0.role }, children: { $0.children })
        XCTAssertTrue(match?.container === upper)
    }

    func testSearchBudgetAndDeadlineBoundUnrelatedContainers() {
        var node = Node(kAXGroupRole)
        for _ in 0..<100 { node = Node(kAXGroupRole, [node]) }
        var reads = 0
        XCTAssertNil(PermissionListAnchorSearch.first(in: node, role: { $0.role }, children: { reads += 1; return $0.children }))
        XCTAssertLessThanOrEqual(reads, 10)
        XCTAssertNil(PermissionListAnchorSearch.first(in: node, role: { $0.role }, children: {
            XCTFail("Expired search must not read children")
            return $0.children
        }, shouldContinue: { false }))
    }

    func testControlsGeometryUsesContainerBottomAndRejectsOffscreenUpperList() {
        let container = CGRect(x: 412, y: 405.5, width: 460, height: 384.5)
        let buttons = [CGRect(x: 419.5, y: 773.5, width: 9.5, height: 9.5),
                       CGRect(x: 444.5, y: 777.5, width: 9.5, height: 1.5)]
        XCTAssertEqual(PermissionListAnchorSearch.visibleFrame(container: container, buttons: buttons,
                                                              viewport: CGRect(x: 400, y: 350, width: 500, height: 600)), container)
        XCTAssertNil(PermissionListAnchorSearch.visibleFrame(container: container, buttons: buttons,
                                                            viewport: CGRect(x: 400, y: 800, width: 500, height: 150)))
        XCTAssertNil(PermissionListAnchorSearch.visibleFrame(container: container, buttons: [buttons[0]], viewport: container))
    }

    func testOverflowingListUsesItsPinnedVisibleControlsEdge() {
        let viewport = CGRect(x: 400, y: 350, width: 500, height: 600)
        let container = CGRect(x: 412, y: 350, width: 460, height: 980)
        let buttons = [CGRect(x: 419.5, y: 933.5, width: 9.5, height: 9.5),
                       CGRect(x: 444.5, y: 937.5, width: 9.5, height: 1.5)]
        let visible = PermissionListAnchorSearch.visibleFrame(container: container, buttons: buttons, viewport: viewport)
        XCTAssertEqual(visible, CGRect(x: 412, y: 350, width: 460, height: 600))
    }

    func testQuartzConversionUsesPrimaryScreenOriginForEveryDisplay() {
        for (quartz, expectedY) in [(CGRect(x: -1500, y: 650, width: 500, height: 400), CGFloat(390)),
                                    (CGRect(x: 0, y: -900, width: 500, height: 300), CGFloat(2040))] {
            let appKit = PermissionListAnchorSearch.appKitRect(fromQuartz: quartz, primaryScreenTop: 1440)
            XCTAssertEqual(appKit.minX, quartz.minX)
            XCTAssertEqual(appKit.minY, expectedY)
            XCTAssertEqual(appKit.size, quartz.size)
        }
    }

    func testLiveSettingsListGeometry() async throws {
        guard ProcessInfo.processInfo.environment["OCU_TEST_LIVE_SETTINGS_ANCHOR"] == "1" else {
            throw XCTSkip("Opt-in read-only inspection of the open System Settings permission page")
        }
        let reader = await MainActor.run { PermissionSettingsWindowReader() }
        var found = false
        for _ in 0..<80 {
            let context = await MainActor.run { reader.context(requireFrontmost: false) }
            if let context, let list = context.permissionListFrame {
                print("Live Settings window=\(context.bounds) list=\(list)")
                XCTAssertTrue(context.bounds.insetBy(dx: -2, dy: -2).contains(list))
                if let output = ProcessInfo.processInfo.environment["OCU_TEST_LIVE_ANCHOR_OUTPUT"] {
                    let payload = ["window": [context.bounds.minX, context.bounds.minY, context.bounds.width, context.bounds.height],
                                   "list": [list.minX, list.minY, list.width, list.height]]
                    try JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: output))
                }
                found = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(found, "Expected the upper permission list controls")
    }
}
