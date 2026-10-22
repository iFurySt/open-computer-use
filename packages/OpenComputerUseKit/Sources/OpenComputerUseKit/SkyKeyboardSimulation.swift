import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct SkyKeyboardTarget {
    let windowID: CGWindowID
    let pid: pid_t
}

/// A `cmd`-chord expressed the way AppKit menus advertise their key
/// equivalents: `AXMenuItemCmdChar` plus the `AXMenuItemCmdModifiers` bitmask
/// (1 = shift, 2 = option, 4 = control; 8 marks a non-command equivalent).
struct SkyMenuKeyEquivalent: Equatable, Sendable {
    let character: String
    let modifiers: Int
}

/// Menu-bar key equivalents (`cmd+a`, `cmd+c`, `cmd+t`, ...) are dispatched by
/// AppKit through `NSMenu`, which only fires for the active app. A background
/// target instead needs the menu item invoked directly, which is exactly what
/// the user's keypress would have triggered. Only single-character keys with
/// a command modifier map to a menu equivalent; everything else (arrows,
/// return, plain characters, non-command chords) is delivered as key events.
func skyMenuKeyEquivalent(for parsed: ParsedKeyPress) -> SkyMenuKeyEquivalent? {
    guard parsed.modifiers.contains(where: { $0.flag == .maskCommand }),
          parsed.displayValue.count == 1
    else {
        return nil
    }

    var modifiers = 0
    for modifier in parsed.modifiers {
        switch modifier.flag {
        case .maskShift:
            modifiers |= 1
        case .maskAlternate:
            modifiers |= 2
        case .maskControl:
            modifiers |= 4
        default:
            break
        }
    }
    return SkyMenuKeyEquivalent(character: parsed.displayValue.uppercased(), modifiers: modifiers)
}

func skyMenuItemMatches(cmdChar: String?, cmdModifiers: Int?, enabled: Bool?, equivalent: SkyMenuKeyEquivalent) -> Bool {
    guard let cmdChar, enabled != false else {
        return false
    }
    return cmdChar.uppercased() == equivalent.character && (cmdModifiers ?? 0) == equivalent.modifiers
}

/// `press_menu`'s path, "Format > Font > Show Fonts": a menu bar title, then each item down to
/// the command. A title that itself contains ">" cannot be named.
func menuPathTitles(_ path: String) throws -> [String] {
    let titles = path.split(separator: ">", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard titles.count >= 2, !titles.contains(where: \.isEmpty) else {
        throw ComputerUseError.invalidArguments("path must name a menu and an item, such as File > Save As…")
    }
    return titles
}

/// Case-insensitive, ignoring surrounding spaces, with "..." standing for "…".
func menuTitleMatches(_ requested: String, _ title: String?) -> Bool {
    guard let title else {
        return false
    }
    func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "...", with: "…").lowercased()
    }
    return normalized(requested) == normalized(title)
}

/// Owner check for keyboard targets. Unlike `sky_click`, the window does not
/// need to be on-screen: keyboard delivery is process-addressed, so a window on
/// another Space or hidden app is a valid target as long as it still exists
/// and belongs to the snapshot's process.
func skyKeyWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t
) -> Bool {
    windowInfo.contains { info in
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            number.uint32Value == windowID,
            let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber
        else {
            return false
        }

        return ownerPID.int32Value == pid
    }
}

/// `sky_key`: deliver keyboard input to a background window without changing
/// the real foreground app.
///
/// Keyboard events posted to a pid reach any AppKit window, but Chromium and
/// Electron only insert text while their NSWindow is key (page focus is driven
/// by `OnWindowIsKeyChanged`). The recipe therefore reuses the `sky_click`
/// target-only synthetic-active state, then posts yabai's key-window record
/// pair so the target app makes the window key internally, waits for it to
/// take effect, delivers the ordinary `CGEvent.postToPid` keyboard events (or
/// presses the matching menu item for command chords), and releases the
/// synthetic state again. The real frontmost app keeps its active, key and
/// first-responder state throughout; the target is never raised and the
/// pointer never moves.
enum SkyKeyboardDispatcher {
    private static let dispatchLock = NSLock()
    static let keyWindowFallbackSettleDefaultMilliseconds = 10.0
    static let releaseSettleDefaultMilliseconds = 10.0
    /// The records and key events are ordered, but target applications can
    /// process them asynchronously. macOS 26 live testing dropped occasional
    /// keys with zero delay, so retain a small cross-version safety margin.
    static let keyWindowFallbackSettle = InputTiming.milliseconds(
        "OPEN_COMPUTER_USE_SKY_KEY_SETTLE_MS",
        default: keyWindowFallbackSettleDefaultMilliseconds
    )
    static let releaseSettle = InputTiming.milliseconds(
        "OPEN_COMPUTER_USE_SKY_KEY_RELEASE_MS",
        default: releaseSettleDefaultMilliseconds
    )

    static func typeText(
        target: SkyKeyboardTarget,
        text: String,
        spi: SkyLightSPI = .shared
    ) throws {
        try deliver(to: target, spi: spi) {
            try InputSimulation.typeText(text, pid: target.pid)
        }
    }

    static func pressKey(
        target: SkyKeyboardTarget,
        key: String,
        spi: SkyLightSPI = .shared
    ) throws {
        // Reject bad key specs before touching the target's focus state.
        let parsed = try KeyPressParser.parse(key)
        try deliver(to: target, spi: spi) {
            if let equivalent = skyMenuKeyEquivalent(for: parsed),
               let item = menuItem(matching: equivalent, pid: target.pid) {
                try requireUsableComputerUseSession()
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                guard result == .success else {
                    throw ComputerUseError.message(
                        "sky_key could not press the menu item for '\(key)' (AXError \(result.rawValue))"
                    )
                }
                Thread.sleep(forTimeInterval: 0.1)
                return
            }

            try InputSimulation.pressKey(key, pid: target.pid)
        }
    }

    private static func deliver(
        to target: SkyKeyboardTarget,
        spi: SkyLightSPI,
        _ body: () throws -> Void
    ) throws {
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "key_method 'sky_key' is unavailable: \(spi.capability.unavailableReason)"
            )
        }

        dispatchLock.lock()
        defer {
            dispatchLock.unlock()
        }

        try validate(target: target)

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            try body()
            return
        }

        let start = TimingLog.now()
        let focusContext = try spi.beginSyntheticTargetFocus(
            targetPID: target.pid,
            targetWindowID: target.windowID
        )
        do {
            try spi.makeSyntheticTargetWindowKey(focusContext)
            TimingLog.log("sky_key.activate", since: start)
            let keyStart = TimingLog.now()
            waitForKeyWindow(target, spi: spi)
            TimingLog.log("sky_key.key_window", since: keyStart)
            let deliverStart = TimingLog.now()
            try body()
            TimingLog.log("sky_key.deliver", since: deliverStart)
            if releaseSettle > 0 {
                Thread.sleep(forTimeInterval: releaseSettle)
            }
        } catch {
            try? spi.endSyntheticTargetFocus(focusContext)
            throw error
        }
        try spi.endSyntheticTargetFocus(focusContext)
        TimingLog.log("sky_key.total", since: start)
    }

    private static func waitForKeyWindow(_ target: SkyKeyboardTarget, spi: SkyLightSPI) {
        if keyWindowFallbackSettle > 0 {
            Thread.sleep(forTimeInterval: keyWindowFallbackSettle)
        }
    }

    private static func validate(target: SkyKeyboardTarget) throws {
        // A hidden app (cmd+h) never makes its windows key, so keys would be
        // silently dropped. Fail closed instead of unhiding on the user's behalf.
        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable(
                "sky_key target app is hidden. Unhide it first; sky_key does not change window visibility."
            )
        }

        // `.optionAll`, not `.optionIncludingWindow`: the latter omits windows
        // that are off-screen (hidden app, minimized, or on another Space).
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        guard skyKeyWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid
        ) else {
            throw ComputerUseError.stateUnavailable(
                "sky_key target window no longer exists or is no longer owned by the target app. Run get_app_state again."
            )
        }
    }

    // MARK: - Menu-bar key equivalents

    private static func menuItem(matching equivalent: SkyMenuKeyEquivalent, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = copyValue(application, kAXMenuBarAttribute) else {
            return nil
        }
        return firstMenuItem(in: menuBar as! AXUIElement, levels: 6) { child in
            copyValue(child, kAXRoleAttribute) as? String == kAXMenuItemRole as String
                && skyMenuItemMatches(
                    cmdChar: copyValue(child, "AXMenuItemCmdChar") as? String,
                    cmdModifiers: (copyValue(child, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                    enabled: (copyValue(child, kAXEnabledAttribute) as? NSNumber)?.boolValue,
                    equivalent: equivalent
                )
        }
    }

    /// Depth-first, at most `levels` below `element`. A menu bar title's or a submenu's
    /// items sit two levels down, inside its AXMenu.
    private static func firstMenuItem(in element: AXUIElement, levels: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard levels > 0 else {
            return nil
        }

        for child in copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if matches(child) {
                return child
            }

            if let nested = firstMenuItem(in: child, levels: levels - 1, where: matches) {
                return nested
            }
        }

        return nil
    }

    // MARK: - Menu paths

    /// `press_menu`: press the item at `path` (["Format", "Font", "Show Fonts"]) through
    /// AXPress, with no key or pointer event, so the app can stay in the background. Each
    /// title is looked up among the items of the menu named before it; a miss lists them.
    static func pressMenuItem(path: [String], pid: pid_t) throws {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = copyValue(application, kAXMenuBarAttribute) else {
            throw ComputerUseError.stateUnavailable("The app has no menu bar.")
        }
        var item = menuBar as! AXUIElement
        for (depth, title) in path.enumerated() {
            let menu = item
            guard let next = firstMenuItem(in: menu, levels: 2, where: {
                isMenuItem($0) && menuTitleMatches(title, copyValue($0, kAXTitleAttribute) as? String)
            }) else {
                let place = depth == 0 ? "the menu bar" : path[..<depth].joined(separator: " > ")
                throw ComputerUseError.message(
                    "No menu item '\(title)' in \(place). Items: \(menuItemTitles(in: menu).joined(separator: ", "))"
                )
            }
            item = next
        }

        let joined = path.joined(separator: " > ")
        // Pressing a menu title or a submenu would open it on screen instead of running a command.
        if firstMenuItem(in: item, levels: 2, where: isMenuItem) != nil {
            throw ComputerUseError.message(
                "\(joined) opens a menu. Add one of its items: \(menuItemTitles(in: item).joined(separator: ", "))"
            )
        }

        // AppKit accepts AXPress on a disabled item and does nothing, so the press would report
        // success. Like the key-equivalent lookup above, trust the item's enabled state.
        if (copyValue(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == false {
            throw ComputerUseError.message("\(joined) is disabled, so it was not pressed.")
        }

        try requireUsableComputerUseSession()
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else {
            throw ComputerUseError.message("Could not press \(joined) (AXError \(result.rawValue)).")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    private static func isMenuItem(_ element: AXUIElement) -> Bool {
        let role = copyValue(element, kAXRoleAttribute) as? String
        return role == kAXMenuItemRole as String || role == kAXMenuBarItemRole as String
    }

    private static func menuItemTitles(in menu: AXUIElement) -> [String] {
        var titles: [String] = []
        _ = firstMenuItem(in: menu, levels: 2) { element in
            if isMenuItem(element), let title = copyValue(element, kAXTitleAttribute) as? String, !title.isEmpty {
                titles.append(title)
            }
            return false
        }
        return titles
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
