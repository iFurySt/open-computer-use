import ApplicationServices
@testable import OpenComputerUseKit
import XCTest

final class AXActiveMenuTests: XCTestCase {
    final class Node {
        let role: String
        var pid: pid_t? = 42
        var selected = false
        var visible: Bool?
        var expanded: Bool?
        var frame: CGRect? = CGRect(x: 64, y: -41, width: 466, height: 671)
        weak var parent: Node?
        var children: [Node] = []
        var selectedChildren: [Node] = []
        var visibleChildren: [Node] = []

        init(_ role: String, children: [Node] = []) {
            self.role = role
            self.children = children
            for child in children {
                child.parent = self
            }
        }
    }

    func reader(onRead: @escaping (Node, String) -> Void = { _, _ in }) -> AXMenuReader<Node> {
        AXMenuReader(
            owner: { $0.pid }, role: { $0.role }, selected: { $0.selected },
            visible: { $0.visible }, expanded: { $0.expanded }, frame: { $0.frame }, parent: { $0.parent },
            children: { node, attribute in
                onRead(node, attribute)
                switch attribute {
                case kAXSelectedChildrenAttribute: return node.selectedChildren
                case "AXVisibleChildren": return node.visibleChildren
                default: return node.children
                }
            }, equal: { $0 === $1 }
        )
    }

    struct Fixture {
        let bar: Node
        let selected: Node
        let menu: Node
        let export: Node
    }

    func fixture() -> Fixture {
        let export = Node(kAXMenuItemRole)
        let menu = Node(kAXMenuRole, children: [export])
        let selected = Node(kAXMenuBarItemRole, children: [menu])
        selected.selected = true
        menu.visible = true
        return Fixture(bar: Node(kAXMenuBarRole, children: [selected]), selected: selected, menu: menu, export: export)
    }

    func testSelectedMenuExposesOriginalSemanticHandlesAndLeavesClosedMenusUnread() throws {
        let fixture = fixture()
        let hiddenMenu = Node(kAXMenuRole, children: [Node(kAXMenuItemRole)])
        let closed = Node(kAXMenuBarItemRole, children: [hiddenMenu])
        fixture.bar.children.append(closed)
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42, validateWindow: { true },
            reader: reader { node, _ in
                XCTAssertFalse(node === closed || node === hiddenMenu, "未打开菜单不可递归读取")
            }
        )
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertTrue(tree.roots.first === fixture.menu)
        let items = try XCTUnwrap(tree.children(of: fixture.menu, equal: { $0 === $1 }))
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first === fixture.export)
    }

    func testSelectedChildrenAttributeCanIdentifyActiveMenu() {
        let fixture = fixture()
        fixture.selected.selected = false
        fixture.bar.selectedChildren = [fixture.selected]
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertTrue(tree.roots.first === fixture.menu)
    }

    func testFocusedDetachedMenuAndFocusedMenuItemAreSupported() {
        let fixture = fixture()
        fixture.selected.selected = false
        for focus in [fixture.menu, fixture.export] {
            let tree = readActiveAXMenus(menuBar: nil, focused: { focus }, pid: 42,
                                         validateWindow: { true }, reader: reader())
            XCTAssertTrue(tree.roots.first === fixture.menu)
            XCTAssertEqual(tree.entries.count, 2)
        }
    }

    func testOrdinaryFocusedControlDoesNotExposeMenus() {
        let fixture = fixture()
        fixture.selected.selected = false
        let button = Node(kAXButtonRole)
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { button }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testForeignOrUnknownOwnersAreExcludedAtEveryMenuLevel() {
        for owner: pid_t? in [nil, 99] {
            for level in 0 ... 3 {
                let fixture = fixture()
                [fixture.bar, fixture.selected, fixture.menu, fixture.export][level].pid = owner
                let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                             validateWindow: { true }, reader: reader())
                XCTAssertFalse(tree.entries.contains { $0.element.pid != 42 })
                if level < 3 {
                    XCTAssertTrue(tree.roots.isEmpty)
                } else {
                    XCTAssertEqual(tree.entries.count, 1)
                }
            }
        }
    }

    func testOnlySelectedOrFocusedSubmenuExpands() {
        for active in [false, true] {
            let fixture = fixture()
            let submenuItem = Node(kAXMenuItemRole)
            let submenu = Node(kAXMenuRole, children: [submenuItem])
            fixture.export.children = [submenu]
            submenu.parent = fixture.export
            fixture.export.selected = active
            fixture.export.expanded = active
            let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                         validateWindow: { true }, reader: reader())
            XCTAssertEqual(tree.entries.contains { $0.element === submenuItem }, active)
        }
        let fixture = fixture()
        let submenuItem = Node(kAXMenuItemRole)
        let submenu = Node(kAXMenuRole, children: [submenuItem])
        fixture.export.children = [submenu]
        submenu.parent = fixture.export
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { submenuItem }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertTrue(tree.entries.contains { $0.element === submenuItem })
    }

    func testClosingMenuDuringReadDiscardsObservation() {
        let fixture = fixture()
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42, validateWindow: { true },
            reader: reader { node, _ in
                if node === fixture.menu { fixture.selected.selected = false }
            }
        )
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertTrue(tree.entries.isEmpty)
    }

    func testChangedFocusIsReadAgainRatherThanReusingOldMenuHandle() {
        let fixture = fixture()
        var reads = 0
        let tree = readActiveAXMenus(menuBar: nil, focused: {
            reads += 1
            return reads == 1 ? fixture.export : nil
        }, pid: 42, validateWindow: { true }, reader: reader())
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(tree.roots.isEmpty)
    }

    func testWindowIdentityChangeDiscardsMenuAndInitialFailureAvoidsMenuTraversal() {
        let fixture = fixture()
        var validations = 0
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42, validateWindow: {
            validations += 1
            return validations == 1
        }, reader: reader())
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertEqual(validations, 2)
        let rejected = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            validateWindow: { false }, reader: reader { node, _ in
                XCTAssertFalse(node === fixture.menu, "主窗口校验失败后不可遍历菜单项")
            }
        )
        XCTAssertTrue(rejected.roots.isEmpty)
    }

    func testDeduplicationCyclesAndNodeDepthBudgets() {
        let fixture = fixture()
        fixture.menu.visibleChildren = [fixture.export]
        fixture.export.selected = true
        fixture.export.children = [fixture.menu]
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { fixture.export }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertEqual(tree.roots.count, 1)
        XCTAssertEqual(tree.entries.count, 2)
        for limit in [0, 1, 2] {
            let limited = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                            maximumNodes: limit, validateWindow: { true }, reader: reader())
            XCTAssertLessThanOrEqual(limited.entries.count, limit)
        }
        let shallow = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                        maximumDepth: 1, validateWindow: { true }, reader: reader())
        XCTAssertEqual(shallow.entries.count, 1)
    }

    func testPublicationRestoresOnlyReturnedHandlesOnce() {
        let fixture = fixture()
        let hiddenMenu = Node(kAXMenuRole)
        fixture.export.children = [hiddenMenu]
        var restored: [Node] = []
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            prepareForPublication: { restored.append($0); return true },
            validateWindow: { true }, reader: reader()
        )
        XCTAssertEqual(tree.entries.count, 2)
        XCTAssertEqual(restored.count, tree.entries.count)
        XCTAssertTrue(zip(restored, tree.entries).allSatisfy { $0.0 === $0.1.element })
        XCTAssertFalse(restored.contains { $0 === fixture.bar || $0 === fixture.selected || $0 === hiddenMenu })
    }

    func testTimeoutRestoreFailureDiscardsEntireActiveTree() {
        let fixture = fixture()
        var restorations = 0
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42,
            prepareForPublication: { _ in restorations += 1; return false },
            validateWindow: { true }, reader: reader()
        )
        XCTAssertEqual(restorations, 1)
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertTrue(tree.entries.isEmpty)
    }

    func testDeadlineDuringTimeoutRestoreDiscardsActiveTree() {
        let fixture = fixture()
        var expired = false
        var restorations = 0
        let tree = readActiveAXMenus(
            menuBar: fixture.bar, focused: { nil }, pid: 42, expired: { expired },
            prepareForPublication: { _ in
                restorations += 1
                expired = true
                return true
            }, validateWindow: { true }, reader: reader()
        )
        XCTAssertEqual(restorations, 1)
        XCTAssertTrue(tree.roots.isEmpty)
        XCTAssertTrue(tree.entries.isEmpty)
    }
}

/// review 追加：读不到 / 快速无菜单路径 / 截断 / 窗口按钮排序。
extension AXActiveMenuTests {
    func testMenuLevelWindowWithoutReadableMenuIsReportedUnreadable() {
        let fixture = fixture()
        // 主窗口校验失败（应用不回答）：有菜单层级窗口就报 unreadable，没有就是普通"无菜单"。
        for present in [false, true] {
            let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                         menuWindowPresent: present, validateWindow: { false }, reader: reader())
            XCTAssertTrue(tree.roots.isEmpty)
            XCTAssertEqual(tree.menuWindowUnreadable, present)
            XCTAssertEqual(tree.notes, present ? [AXActiveMenuNote.unreadable] : [])
        }
        let expired = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42, expired: { true },
                                        menuWindowPresent: true, validateWindow: { true }, reader: reader())
        XCTAssertTrue(expired.menuWindowUnreadable, "预算一开始就耗尽也不能伪装成没有菜单")
        let found = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                      menuWindowPresent: true, validateWindow: { true }, reader: reader())
        XCTAssertTrue(found.roots.first === fixture.menu)
        XCTAssertFalse(found.menuWindowUnreadable)
        XCTAssertTrue(found.notes.isEmpty)
        fixture.selected.selected = false
        let none = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                     menuWindowPresent: true, validateWindow: { true }, reader: reader())
        XCTAssertTrue(none.menuWindowUnreadable, "菜单窗口在屏但 AX 没有任何候选，同样是读不到")
        XCTAssertEqual(
            AXActiveMenuNote.unreadable,
            "[A menu appears to be open but did not answer accessibility reads; "
                + "do not click its opener again. Press Escape to close it or take a screenshot.]"
        )
    }

    func testWindowTriageSkipsDiscoveryWithoutMenuCandidateWindow() {
        func window(_ id: CGWindowID, pid: pid_t = 42, layer: Int) -> AXMenuWindowEvidence {
            AXMenuWindowEvidence(windowID: id, pid: pid, bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
                                 layer: layer, onScreen: true, alpha: 1)
        }
        let popUp = AXMenuWindowEvidence.popUpMenuLevel
        XCTAssertEqual(popUp, 101)
        var offScreen = window(13, layer: popUp)
        offScreen.onScreen = false
        var transparent = window(14, layer: popUp)
        transparent.alpha = 0
        // layer 0 普通窗口、别的进程的菜单、目标窗口本身、离屏或透明窗口：都不触发 AX 发现。
        let quietWindows = [window(11, layer: 0), window(12, pid: 99, layer: popUp), window(11, layer: popUp),
                            offScreen, transparent]
        let quiet = AXMenuWindowTriage(windows: quietWindows, pid: 42, rootWindowID: 11)
        XCTAssertTrue(quiet.skipsDiscovery)
        XCTAssertFalse(quiet.menuLevelWindowPresent)
        let skipped: AXActiveMenuTree<Node> = quiet.discover { _ in
            XCTFail("没有 layer > 0 的在屏窗口不可进入 AX 发现")
            return .init()
        }
        XCTAssertTrue(skipped.roots.isEmpty)
        XCTAssertFalse(skipped.menuWindowUnreadable)
        // 浮动面板等非菜单层级窗口：要跑发现，但不能作为"菜单在但读不到"的证据。
        let floating = AXMenuWindowTriage(windows: [window(11, layer: 0), window(15, layer: 3)],
                                          pid: 42, rootWindowID: 11)
        XCTAssertFalse(floating.skipsDiscovery)
        XCTAssertFalse(floating.menuLevelWindowPresent)
        let menu = AXMenuWindowTriage(windows: [window(11, layer: 0), window(16, layer: popUp)],
                                      pid: 42, rootWindowID: 11)
        XCTAssertFalse(menu.skipsDiscovery)
        XCTAssertTrue(menu.menuLevelWindowPresent)
        var presentSeen: Bool?
        let discovered: AXActiveMenuTree<Node> = menu.discover { present in
            presentSeen = present
            return .init(menuWindowUnreadable: present)
        }
        XCTAssertEqual(presentSeen, true)
        XCTAssertTrue(discovered.menuWindowUnreadable)
    }

    func testNodeAndDepthCapsMarkTreeTruncatedAndCountShownItems() {
        let fixture = fixture()
        fixture.menu.children = (0 ..< 5).map { _ in Node(kAXMenuItemRole) }
        for child in fixture.menu.children {
            child.parent = fixture.menu
        }
        let capped = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                       maximumNodes: 3, validateWindow: { true }, reader: reader())
        XCTAssertTrue(capped.roots.first === fixture.menu)
        XCTAssertEqual(capped.entries.count, 3)
        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.itemCount, 2)
        XCTAssertEqual(capped.notes, ["[menu truncated: 2 items shown, more exist]"])
        let full = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                     validateWindow: { true }, reader: reader())
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(full.itemCount, 5)
        XCTAssertTrue(full.notes.isEmpty)
        let shallow = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                        maximumDepth: 1, validateWindow: { true }, reader: reader())
        XCTAssertEqual(shallow.entries.count, 1)
        XCTAssertTrue(shallow.truncated, "深度上限同样是截断，不能让菜单看起来到此为止")
        XCTAssertEqual(shallow.itemCount, 0)
        XCTAssertGreaterThanOrEqual(AXMenuDiscoveryBudget.minimumNodes, 2048)
    }

    func testWalkBudgetExhaustionKeepsPartialTreeAsTruncated() {
        let fixture = fixture()
        fixture.menu.children = (0 ..< 5).map { _ in Node(kAXMenuItemRole) }
        for child in fixture.menu.children {
            child.parent = fixture.menu
        }
        var checks = 0
        // 预算在第 4 次检查时用完：根和前三个节点已进树，剩余的标成截断而不是整棵丢掉。
        let tree = readActiveAXMenus(menuBar: fixture.bar, focused: { nil }, pid: 42,
                                     walkBudgetExhausted: { checks += 1; return checks > 3 },
                                     validateWindow: { true }, reader: reader())
        XCTAssertTrue(tree.roots.first === fixture.menu)
        XCTAssertEqual(tree.entries.count, 3)
        XCTAssertTrue(tree.truncated)
        XCTAssertFalse(tree.menuWindowUnreadable)
        XCTAssertEqual(AXMenuDiscoveryBudget.verificationShare, 0.4, accuracy: 0.000001)
    }

    func testWindowChromeButtonsArePartitionedAfterOtherCandidatesInOrder() {
        typealias Candidate = (name: String, subrole: String?)
        let nodes: [Candidate] = [("close", kAXCloseButtonSubrole as String), ("toolbar", nil),
                                  ("minimize", kAXMinimizeButtonSubrole as String),
                                  ("zoom", kAXZoomButtonSubrole as String), ("send", nil),
                                  ("fullscreen", kAXFullScreenButtonSubrole as String),
                                  ("search", "AXSearchField")]
        let split = partitionWindowChromeButtons(nodes) { $0.subrole }
        XCTAssertEqual(split.regular.map(\.name), ["toolbar", "send", "search"])
        XCTAssertEqual(split.deferred.map(\.name), ["close", "minimize", "zoom", "fullscreen"])
        let plain = partitionWindowChromeButtons(["a", "b"]) { _ in nil }
        XCTAssertEqual(plain.regular, ["a", "b"])
        XCTAssertTrue(plain.deferred.isEmpty)
    }
}
