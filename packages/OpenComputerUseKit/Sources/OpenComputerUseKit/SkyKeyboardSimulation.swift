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

    /// `holdMs` keeps the window key for the whole hold. A command chord is a
    /// menu press here, which has no duration, so it cannot be held.
    static func pressKey(
        target: SkyKeyboardTarget,
        key: String,
        holdMs: Int? = nil,
        spi: SkyLightSPI = .shared
    ) throws {
        // Reject bad key specs before touching the target's focus state.
        let parsed = try KeyPressParser.parse(key)
        let equivalent = skyMenuKeyEquivalent(for: parsed)
        if holdMs != nil, equivalent != nil {
            throw ComputerUseError.invalidArguments(
                "hold_ms cannot hold '\(key)' with key_method 'sky_key', which presses command chords through the app's menu. Use key_method 'auto' to hold it."
            )
        }
        try deliver(to: target, spi: spi) {
            if let equivalent,
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

            try InputSimulation.pressKey(key, pid: target.pid, holdMs: holdMs)
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
        return firstMenuItem(in: menuBar as! AXUIElement, matching: equivalent, depth: 0)
    }

    private static func firstMenuItem(in element: AXUIElement, matching equivalent: SkyMenuKeyEquivalent, depth: Int) -> AXUIElement? {
        guard depth < 6 else {
            return nil
        }

        for child in copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let role = copyValue(child, kAXRoleAttribute) as? String
            if role == kAXMenuItemRole as String,
               skyMenuItemMatches(
                   cmdChar: copyValue(child, "AXMenuItemCmdChar") as? String,
                   cmdModifiers: (copyValue(child, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
                   enabled: (copyValue(child, kAXEnabledAttribute) as? NSNumber)?.boolValue,
                   equivalent: equivalent
               ) {
                return child
            }

            if let nested = firstMenuItem(in: child, matching: equivalent, depth: depth + 1) {
                return nested
            }
        }

        return nil
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
