import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

extension AXActiveMenuTests {
    private func window(for node: Node) -> AXMenuWindowEvidence {
        AXMenuWindowEvidence(windowID: 12, pid: 42, bounds: node.frame ?? .zero,
                             layer: 101, onScreen: true, alpha: 1)
    }

    func testUnknownVisibilityUsesGeometryWithOneInitialAndOneFinalWindowQuery() {
        let fixture = fixture()
        fixture.menu.visible = nil
        var queries = 0
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { Node(kAXWindowRole) }, pid: 42,
            rootWindowID: 11, windowEvidence: {
                queries += 1
                return [self.window(for: fixture.menu)]
            }, validateWindow: { true }, reader: reader()
        )
        XCTAssertTrue(tree.roots.first === fixture.menu)
        XCTAssertTrue(tree.entries.contains { $0.element === fixture.export })
        XCTAssertEqual(queries, 2)
    }

    func testSelectedWithoutOpenEvidenceDoesNotPublishHiddenMenu() {
        let fixture = fixture()
        fixture.menu.visible = nil
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testNoCandidateDoesNotQueryWindowsOrValidateRoot() {
        let fixture = fixture()
        fixture.selected.selected = false
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { Node(kAXCheckBoxRole) }, pid: 42,
            windowEvidence: { XCTFail("没有菜单候选不可查询 CG"); return [] },
            validateWindow: { XCTFail("没有菜单候选不可额外查询 root"); return false },
            reader: reader { node, _ in XCTAssertTrue(node === fixture.bar) }
        )
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testExplicitHiddenOrCollapsedRejectsDespiteMatchingGeometry() {
        for state in 0 ... 2 {
            let fixture = fixture()
            fixture.menu.visible = nil
            if state == 0 { fixture.menu.visible = false }
            if state == 1 { fixture.selected.visible = false }
            if state == 2 { fixture.selected.expanded = false }
            let tree = readActiveAXMenus(
                menuBar: fixture.bar, focused: { fixture.export }, pid: 42,
                windowEvidence: { XCTFail("明确隐藏不可用 CG 绕过"); return [self.window(for: fixture.menu)] },
                validateWindow: { true }, reader: reader()
            )
            XCTAssertTrue(tree.roots.isEmpty)
        }
    }

    func testVisibleChildrenEvidenceDoesNotRequireOptionalVisibleAttribute() {
        let fixture = fixture()
        fixture.menu.visible = nil
        fixture.selected.visibleChildren = [fixture.menu]
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            windowEvidence: { XCTFail("已有 AX 可见证据不需 CG"); return [] },
            validateWindow: { true }, reader: reader()
        )
        XCTAssertTrue(tree.roots.first === fixture.menu)
    }

    func testFocusedLeafCollapsedFlagDoesNotHideItsParentMenu() {
        let fixture = fixture()
        fixture.menu.visible = nil
        fixture.export.expanded = false
        let tree = readActiveAXMenus(menuBar: nil, focused: { fixture.export }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertTrue(tree.roots.first === fixture.menu)
    }

    func testGeometryRejectsForeignRootInvisibleOrdinaryAndMismatchedWindows() {
        let fixture = fixture()
        let matching = window(for: fixture.menu)
        var invalid: [AXMenuWindowEvidence] = []
        var candidate = matching
        candidate.pid = 99
        invalid.append(candidate)
        candidate = matching
        candidate.windowID = 11
        invalid.append(candidate)
        candidate = matching
        candidate.onScreen = false
        invalid.append(candidate)
        candidate = matching
        candidate.alpha = 0
        invalid.append(candidate)
        candidate = matching
        candidate.layer = 0
        invalid.append(candidate)
        candidate = matching
        candidate.bounds.origin.x += 10
        invalid.append(candidate)
        candidate = matching
        candidate.bounds.size.width += 100
        invalid.append(candidate)
        for value in invalid {
            XCTAssertFalse(value.matches(matching.bounds, pid: 42, excluding: 11))
        }
        XCTAssertTrue(matching.matches(matching.bounds, pid: 42, excluding: 11))
        XCTAssertFalse(matching.matches(.zero, pid: 42, excluding: 11))
    }

    func testGeometryDoesNotExpandUnselectedOrHiddenSubmenus() {
        for selected in [false, true] {
            let fixture = fixture()
            fixture.menu.visible = nil
            let submenu = Node(kAXMenuRole, children: [Node(kAXMenuItemRole)])
            submenu.frame = CGRect(x: 530, y: 20, width: 120, height: 90)
            submenu.visible = false
            fixture.export.children = [submenu]
            fixture.export.selected = selected
            let tree = readActiveAXMenus(
                menuBar: fixture.bar, focused: { nil }, pid: 42,
                windowEvidence: { [self.window(for: fixture.menu), self.window(for: submenu)] },
                validateWindow: { true }, reader: reader()
            )
            XCTAssertTrue(tree.roots.first === fixture.menu)
            XCTAssertFalse(tree.entries.contains { $0.element === submenu })
        }
    }

    func testGeometryMoveDuringTraversalDiscardsObservation() {
        let fixture = fixture()
        fixture.menu.visible = nil
        let original = window(for: fixture.menu)
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            windowEvidence: { [original] }, validateWindow: { true },
            reader: reader { node, _ in
                if node === fixture.menu { fixture.menu.frame?.origin.x += 1 }
            }
        )
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testDeadlineAfterCGQueryDiscardsObservationWithoutRetry() {
        let fixture = fixture()
        fixture.menu.visible = nil
        var expired = false
        var queries = 0
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42, expired: { expired },
            windowEvidence: {
                queries += 1
                expired = true
                return [self.window(for: fixture.menu)]
            }, validateWindow: { XCTFail("到期后不可继续校验"); return true }, reader: reader()
        )
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertEqual(queries, 1)
    }

    func testExpiredDiscoveryNeverExtendsBudgetOrReadsAX() {
        let tree: AXActiveMenuTree<Node> = readActiveAXMenus(
            menuBar: nil, focused: { XCTFail("到期后不可读 AX"); return nil }, pid: 42,
            expired: { true }, foundCandidate: { XCTFail("不可延长已过期预算") },
            validateWindow: { false }, reader: reader()
        )
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testFrozenChildrenOnlyOverrideElementsPresentInActiveTree() {
        let fixture = fixture()
        let ordinaryMenu = Node(kAXMenuRole, children: [Node(kAXMenuItemRole)])
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertNil(tree.children(of: ordinaryMenu, equal: { $0 === $1 }))
        XCTAssertNotNil(tree.children(of: fixture.export, equal: { $0 === $1 }))
        XCTAssertTrue(tree.children(of: fixture.export, equal: { $0 === $1 })?.isEmpty == true)
    }

    func testFinalCGRevalidationRejectsClosedMovedHiddenOrReplacedWindowWithStaleAX() {
        for change in 0 ... 4 {
            let fixture = fixture()
            fixture.menu.visible = nil
            let initial = window(for: fixture.menu)
            var queries = 0
            let tree = readActiveAXMenus(
                menuBar: fixture.bar, focused: { nil }, pid: 42,
                windowEvidence: {
                    queries += 1
                    if queries == 1 { return [initial] }
                    var final = initial
                    switch change {
                    case 0: return []
                    case 1: final.bounds.origin.y += 1
                    case 2: final.onScreen = false
                    case 3: final.windowID += 1
                    default: final.pid = 99
                    }
                    return [final]
                }, validateWindow: { true }, reader: reader()
            )
            XCTAssertEqual(queries, 2)
            XCTAssertTrue(tree.roots.isEmpty, "AX selected/frame 缓存未变也必须拒绝")
        }
    }

    func testMultipleGeometryMenusShareBothWindowQueries() {
        let fixture = fixture()
        fixture.menu.visible = nil
        let submenu = Node(kAXMenuRole, children: [Node(kAXMenuItemRole)])
        submenu.frame = CGRect(x: 530, y: 20, width: 120, height: 90)
        fixture.export.children = [submenu]
        fixture.export.selected = true
        var submenuWindow = window(for: submenu)
        submenuWindow.windowID = 13
        var queries = 0
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            windowEvidence: {
                queries += 1
                return [self.window(for: fixture.menu), submenuWindow]
            }, validateWindow: { true }, reader: reader()
        )
        XCTAssertEqual(queries, 2)
        XCTAssertTrue(tree.entries.contains { $0.element === submenu })
    }

    func testInitiallyUniqueGeometryBecomingAmbiguousDiscardsObservation() {
        let fixture = fixture()
        fixture.menu.visible = nil
        let initial = window(for: fixture.menu)
        var duplicate = initial
        duplicate.windowID += 1
        var queries = 0
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            windowEvidence: {
                queries += 1
                return queries == 1 ? [initial] : [initial, duplicate]
            }, validateWindow: { true }, reader: reader()
        )
        XCTAssertEqual(queries, 2)
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertTrue(tree.entries.isEmpty)
    }
    /// macOS 27 Contacts：菜单打开时菜单栏项与 AXMenu 的 AXExpanded 仍为 false、AXVisible 不支持，
    /// 菜单栏的 AXSelectedChildren 列出该项，CG 菜单窗口比 AX 内容区四边各大 75pt。
    func testMenuBarSelectedChildrenOverrideCollapsedFlagWhenInsetGeometryMatches() throws {
        let fixture = fixture()
        fixture.selected.expanded = false
        fixture.menu.expanded = false
        fixture.menu.visible = nil
        fixture.bar.selectedChildren = [fixture.selected]
        let menuFrame = try XCTUnwrap(fixture.menu.frame)
        let window = AXMenuWindowEvidence(windowID: 12, pid: 42, bounds: menuFrame.insetBy(dx: -75, dy: -75),
                                          layer: 101, onScreen: true, alpha: 1)
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { fixture.selected }, pid: 42,
            rootWindowID: 11, windowEvidence: { [window] }, validateWindow: { true }, reader: reader()
        )
        XCTAssertTrue(tree.roots.first === fixture.menu)
        XCTAssertTrue(tree.entries.contains { $0.element === fixture.export })
    }

    func testCollapsedFlagWithoutSelectedChildrenOrFocusStillRejects() throws {
        let fixture = fixture()
        fixture.selected.expanded = false
        fixture.menu.visible = nil
        let menuFrame = try XCTUnwrap(fixture.menu.frame)
        let window = AXMenuWindowEvidence(windowID: 12, pid: 42, bounds: menuFrame.insetBy(dx: -75, dy: -75),
                                          layer: 101, onScreen: true, alpha: 1)
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            rootWindowID: 11, windowEvidence: { [window] }, validateWindow: { true }, reader: reader()
        )
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testMenuWindowInsetToleranceRejectsOrdinaryContainment() {
        let frame = CGRect(x: 117, y: 34, width: 332, height: 307)
        func evidence(_ bounds: CGRect, layer: Int = 101) -> AXMenuWindowEvidence {
            AXMenuWindowEvidence(windowID: 12, pid: 42, bounds: bounds, layer: layer, onScreen: true, alpha: 1)
        }
        XCTAssertTrue(evidence(frame).matches(frame, pid: 42, excluding: 11))
        XCTAssertTrue(evidence(frame.insetBy(dx: -75, dy: -75)).matches(frame, pid: 42, excluding: 11))
        XCTAssertTrue(evidence(CGRect(x: 42, y: -41, width: 482, height: 457)).matches(frame, pid: 42, excluding: 11))
        XCTAssertFalse(evidence(frame.insetBy(dx: -120, dy: -120)).matches(frame, pid: 42, excluding: 11))
        XCTAssertFalse(evidence(frame.insetBy(dx: 10, dy: 10)).matches(frame, pid: 42, excluding: 11))
        XCTAssertFalse(evidence(frame.offsetBy(dx: 40, dy: 0)).matches(frame, pid: 42, excluding: 11))
        XCTAssertFalse(evidence(frame.insetBy(dx: -75, dy: -75), layer: 0).matches(frame, pid: 42, excluding: 11))
    }

}
