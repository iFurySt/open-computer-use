import AppKit
import Foundation

/// 前台借用：把目标 app 激活到前台，让只有在 frontmost 时才会出现的弹层、菜单、日期选择器和行内编辑器可操作；
/// 记住借用前的前台 app，`return` 或会话结束时归还。只切换激活状态，不移动指针、不改窗口位置。
///
/// macOS 14 起后台进程直接 `activate()` 可能被系统拒绝（协作式激活），所以激活失败时退回
/// LaunchServices 的 `openApplication(at:configuration:)`，等价于 `open -a`。
enum ForegroundBorrow {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var previousFrontmost: NSRunningApplication?

    static func borrow(app query: String) throws -> ToolCallResult {
        let target = try AppDiscovery.resolve(query).runningApplication
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == target.processIdentifier {
            return .text("\(target.localizedName ?? query) is already frontmost; nothing to restore later.")
        }
        lock.withLock {
            // 连续借用多个 app 只记第一次的前台，归还时回到用户真正在用的那个。
            if previousFrontmost == nil, let frontmost,
               frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousFrontmost = frontmost
            }
        }
        guard activate(target) else {
            throw ComputerUseError.stateUnavailable(
                "Could not bring \(target.localizedName ?? query) to the foreground. Observe the app again before acting."
            )
        }
        let restore = lock.withLock { previousFrontmost?.localizedName }
        return .text(
            "\(target.localizedName ?? query) is now frontmost. Observe again before acting; call set_foreground with mode \"return\" when the foreground-only step is done"
                + (restore.map { " to give focus back to \($0)." } ?? ".")
        )
    }

    /// 归还焦点；没有借用记录或原 app 已退出时静默成功。
    static func returnFocus() -> ToolCallResult {
        guard let previous = lock.withLock({ () -> NSRunningApplication? in
            defer { previousFrontmost = nil }
            return previousFrontmost
        }) else {
            return .text("No borrowed foreground to return.")
        }
        guard !previous.isTerminated else {
            return .text("The previous foreground app has quit; nothing to restore.")
        }
        guard activate(previous) else {
            return .text("Could not give focus back to \(previous.localizedName ?? "the previous app").", isError: true)
        }
        return .text("Focus returned to \(previous.localizedName ?? "the previous app").")
    }

    /// 会话结束时的兜底归还：用户不该在 agent 结束后发现焦点还停在被操作的 app 上。
    static func returnFocusIfBorrowed() {
        guard lock.withLock({ previousFrontmost != nil }) else { return }
        _ = returnFocus()
    }

    private static func activate(_ app: NSRunningApplication) -> Bool {
        VisualCursorSupport.performOnMain {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateIgnoringOtherApps])
        }
        if waitUntilFrontmost(app, timeout: 0.4) { return true }
        if let bundleURL = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            let group = DispatchGroup()
            group.enter()
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in group.leave() }
            _ = group.wait(timeout: .now() + 1.5)
        }
        return waitUntilFrontmost(app, timeout: 1.5)
    }

    private static func waitUntilFrontmost(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
}
