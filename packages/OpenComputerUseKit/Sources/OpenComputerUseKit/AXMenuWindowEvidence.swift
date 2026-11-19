import ApplicationServices
import Foundation

/// 几何只用于只读菜单可见性佐证，不证明窗口所有权，也不授权输入。
struct AXMenuWindowEvidence {
    var windowID: CGWindowID
    var pid: pid_t
    var bounds: CGRect
    var layer: Int
    var onScreen: Bool
    var alpha: Double

    /// 可能承载菜单的窗口：目标进程拥有、在屏、可见、layer > 0、几何有效，且不是目标窗口本身。
    /// 分流（要不要跑 AX 发现）与几何佐证共用这一条规则，二者才不会互相漏判。
    func isMenuCandidate(pid: pid_t, excluding rootWindowID: CGWindowID) -> Bool {
        self.pid == pid && windowID != 0 && windowID != rootWindowID
            && onScreen && alpha.isFinite && alpha > 0 && layer > 0 && Self.isValid(bounds)
    }

    /// AppKit 菜单（菜单栏 / 右键 / 弹出按钮 / 状态栏项）所在的 CG 层级。
    static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))

    static func isValid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    func matches(_ frame: CGRect, pid: pid_t, excluding rootWindowID: CGWindowID) -> Bool {
        guard isMenuCandidate(pid: pid, excluding: rootWindowID), Self.isValid(frame) else { return false }
        // CG/AX 均为全局 point。菜单窗口（layer > 0）在 macOS 26+ 带玻璃/阴影内边距：
        // AX 报的是菜单内容区，CG 报的是整个窗口，四边各差约 75pt（Contacts 实测）。
        // 只接受"内容区被窗口包含且每边边距有限"，仍拒绝普通窗口的包含或仅相交。
        let insets = [frame.minX - bounds.minX, frame.minY - bounds.minY,
                      bounds.maxX - frame.maxX, bounds.maxY - frame.maxY]
        return insets.allSatisfy { $0 >= -2 && $0 <= Self.maximumMenuWindowInset }
    }

    /// 菜单窗口内容区到窗口边缘的最大可信边距（pt）。
    static let maximumMenuWindowInset: CGFloat = 96
}

/// 一次 CG 在屏窗口读取就能决定要不要花 AX 发现预算：没有 layer > 0 的在屏窗口就不可能有打开的菜单。
/// 常规无菜单快照因此只付一次 CGWindowListCopyWindowInfo（约 1ms），不再付 80ms 的 AX 预算。
struct AXMenuWindowTriage {
    /// 目标进程拥有的 layer > 0 在屏窗口（不含目标窗口本身），规则与几何佐证一致。
    let candidates: [AXMenuWindowEvidence]

    init(windows: [AXMenuWindowEvidence], pid: pid_t, rootWindowID: CGWindowID) {
        candidates = windows.filter { $0.isMenuCandidate(pid: pid, excluding: rootWindowID) }
    }

    var skipsDiscovery: Bool { candidates.isEmpty }

    /// 只有 kCGPopUpMenuWindowLevel 的窗口才作为"菜单在但读不到"的证据；
    /// 浮动面板、tooltip 等其他 layer > 0 窗口只触发发现、不触发提示，避免误导模型按 Escape。
    var menuLevelWindowPresent: Bool {
        candidates.contains { $0.layer == AXMenuWindowEvidence.popUpMenuLevel }
    }

    /// 没有候选窗口时直接返回"无菜单"，不创建任何 AX 句柄；否则把是否存在菜单层级窗口交给发现逻辑。
    /// 闭包参数：是否存在菜单层级窗口（`menuLevelWindowPresent`）。
    func discover<Element>(_ run: (Bool) -> AXActiveMenuTree<Element>) -> AXActiveMenuTree<Element> {
        skipsDiscovery ? .init() : run(menuLevelWindowPresent)
    }
}
