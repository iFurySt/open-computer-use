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
