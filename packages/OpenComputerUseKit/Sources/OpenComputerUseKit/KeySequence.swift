import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One step of a `key_sequence` call.
public enum KeySequenceStep: Equatable, Sendable {
    /// Hold a single key (or a modifier such as `shift`) down until a later `up`, or the end of the sequence.
    case down(String)
    /// Release a key an earlier `down` is holding.
    case up(String)
    /// Tap a key or chord (`press_key` syntax) while any held keys stay down.
    case press(String)
    /// Wait while held keys stay down.
    case wait(milliseconds: Int)
}

/// A timeline of key-downs, key-ups, taps and waits, delivered to one app in one call so keys can
/// overlap: hold W, tap Space, keep walking. Games read held keys every frame, so walking while
/// jumping needs both keys down at once, which separate `press_key` calls cannot do.
///
/// The whole timeline is validated and every key event is created before the first one is posted,
/// and every key still held at the end is released, so a key is never left stuck down.
public enum KeySequence {
    public static let maximumSteps = 200
    public static let maximumWaitMilliseconds = 5_000
    public static let maximumTotalWaitMilliseconds = 10_000

    struct HeldKey: Equatable {
        let name: String
        let keyCode: CGKeyCode
        /// Set for modifier keys: held modifiers apply to every event sent while they are down.
        let modifierFlag: CGEventFlags?

        static func == (lhs: HeldKey, rhs: HeldKey) -> Bool {
            lhs.keyCode == rhs.keyCode
        }
    }

    enum Resolved: Equatable {
        case down(HeldKey)
        case up(HeldKey)
        case press(ParsedKeyPress)
        case wait(milliseconds: Int)

        static func == (lhs: Resolved, rhs: Resolved) -> Bool {
            switch (lhs, rhs) {
            case let (.down(a), .down(b)), let (.up(a), .up(b)):
                return a == b
            case let (.press(a), .press(b)):
                return a.keyCode == b.keyCode && a.modifiers.map(\.keyCode) == b.modifiers.map(\.keyCode)
            case let (.wait(a), .wait(b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// One posted key event, or a pause, in delivery order.
    enum Action {
        case key(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
        case wait(TimeInterval)
    }

    /// Reads the `steps` argument: an array of objects that each hold exactly one of
    /// `down`, `up`, `press` (strings) or `wait_ms` (a whole number).
    public static func parse(_ raw: Any?) throws -> [KeySequenceStep] {
        guard let list = raw as? [Any] else {
            throw ComputerUseError.invalidArguments("steps must be an array of step objects")
        }

        return try list.enumerated().map { offset, item in
            let number = offset + 1
            guard let object = item as? [String: Any], object.count == 1, let (key, value) = object.first else {
                throw ComputerUseError.invalidArguments(
                    "step \(number) must be an object with exactly one of down, up, press or wait_ms"
                )
            }

            switch key {
            case "down", "up", "press":
                guard let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ComputerUseError.invalidArguments("step \(number): \(key) needs a key name")
                }
                return key == "down" ? .down(text) : key == "up" ? .up(text) : .press(text)
            case "wait_ms":
                return .wait(milliseconds: try waitMilliseconds(value, step: number))
            default:
                throw ComputerUseError.invalidArguments(
                    "step \(number): unknown action '\(key)'; use down, up, press or wait_ms"
                )
            }
        }
    }

    /// A whole number of milliseconds. JSON `true` bridges to an NSNumber that `as? Int` reads as 1,
    /// so booleans are refused before the numeric read.
    private static func waitMilliseconds(_ value: Any, step: Int) throws -> Int {
        let message = "step \(step): wait_ms must be a whole number from 0 to \(maximumWaitMilliseconds)"
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            throw ComputerUseError.invalidArguments(message)
        }
        let number: Double
        if let integer = value as? Int {
            number = Double(integer)
        } else if let double = value as? Double {
            number = double
        } else {
            throw ComputerUseError.invalidArguments(message)
        }
        guard number.isFinite, number.rounded() == number, number >= 0, number <= Double(maximumWaitMilliseconds) else {
            throw ComputerUseError.invalidArguments(message)
        }
        return Int(number)
    }

    /// Checks the whole timeline before anything is sent: known keys, an `up` only for a held key,
    /// no double `down`, and the step and wait limits.
    static func resolve(_ steps: [KeySequenceStep]) throws -> [Resolved] {
        guard !steps.isEmpty else {
            throw ComputerUseError.invalidArguments("steps is empty")
        }
        guard steps.count <= maximumSteps else {
            throw ComputerUseError.invalidArguments("steps has \(steps.count) entries; the limit is \(maximumSteps)")
        }

        var held: [HeldKey] = []
        var totalWait = 0
        return try steps.enumerated().map { offset, step in
            let number = offset + 1
            switch step {
            case .down(let name):
                let key = try heldKey(name, step: number)
                guard !held.contains(key) else {
                    throw ComputerUseError.invalidArguments("step \(number): '\(name)' is already held")
                }
                held.append(key)
                return .down(key)
            case .up(let name):
                let key = try heldKey(name, step: number)
                guard let index = held.firstIndex(of: key) else {
                    throw ComputerUseError.invalidArguments("step \(number): '\(name)' is not held; add a down step for it first")
                }
                held.remove(at: index)
                return .up(key)
            case .press(let specification):
                return .press(try KeyPressParser.parse(specification))
            case .wait(let milliseconds):
                guard (0...maximumWaitMilliseconds).contains(milliseconds) else {
                    throw ComputerUseError.invalidArguments(
                        "step \(number): wait_ms must be a whole number from 0 to \(maximumWaitMilliseconds)"
                    )
                }
                totalWait += milliseconds
                guard totalWait <= maximumTotalWaitMilliseconds else {
                    throw ComputerUseError.invalidArguments(
                        "the waits add up to more than \(maximumTotalWaitMilliseconds) ms"
                    )
                }
                return .wait(milliseconds: milliseconds)
            }
        }
    }

    static func heldKey(_ name: String, step: Int) throws -> HeldKey {
        let token = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "shift":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Shift), modifierFlag: .maskShift)
        case "control", "ctrl":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Control), modifierFlag: .maskControl)
        case "option", "alt":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Option), modifierFlag: .maskAlternate)
        case "cmd", "command", "super", "meta":
            return HeldKey(name: token, keyCode: CGKeyCode(kVK_Command), modifierFlag: .maskCommand)
        default:
            guard !token.contains("+") else {
                throw ComputerUseError.invalidArguments(
                    "step \(step): down/up take one key; hold each key of a chord with its own down step"
                )
            }
            let parsed = try KeyPressParser.parse(token)
            return HeldKey(name: token, keyCode: parsed.keyCode, modifierFlag: nil)
        }
    }

    /// The key events and pauses a resolved timeline posts, in order, with the modifier flags each
    /// event carries. Keys still held at the end are released in reverse order.
    static func actions(for steps: [Resolved]) -> [Action] {
        var actions: [Action] = []
        var held: [HeldKey] = []
        var activeFlags: CGEventFlags = []

        for step in steps {
            switch step {
            case .down(let key):
                if let flag = key.modifierFlag {
                    activeFlags.insert(flag)
                }
                actions.append(.key(keyCode: key.keyCode, down: true, flags: activeFlags))
                held.append(key)
            case .up(let key):
                if let flag = key.modifierFlag {
                    activeFlags.remove(flag)
                }
                actions.append(.key(keyCode: key.keyCode, down: false, flags: activeFlags))
                held.removeAll { $0 == key }
            case .press(let parsed):
                var flags = activeFlags
                for modifier in parsed.modifiers {
                    flags.insert(modifier.flag)
                    actions.append(.key(keyCode: modifier.keyCode, down: true, flags: flags))
                }
                actions.append(.key(keyCode: parsed.keyCode, down: true, flags: flags))
                actions.append(.key(keyCode: parsed.keyCode, down: false, flags: flags))
                for modifier in parsed.modifiers.reversed() {
                    actions.append(.key(keyCode: modifier.keyCode, down: false, flags: flags))
                    if !activeFlags.contains(modifier.flag) {
                        flags.remove(modifier.flag)
                    }
                }
            case .wait(let milliseconds):
                if milliseconds > 0 {
                    actions.append(.wait(Double(milliseconds) / 1000))
                }
            }
        }

        for key in held.reversed() {
            if let flag = key.modifierFlag {
                activeFlags.remove(flag)
            }
            actions.append(.key(keyCode: key.keyCode, down: false, flags: activeFlags))
        }
        return actions
    }

    /// Sends the timeline to `pid`. Every event is created before the first is posted, so a failure
    /// sends nothing; the timeline ends with every held key released.
    static func run(_ steps: [Resolved], pid: pid_t) throws {
        try requireUsableComputerUseSession()
        enum Prepared {
            case event(CGEvent)
            case wait(TimeInterval)
        }

        let prepared: [Prepared] = try actions(for: steps).map { action in
            switch action {
            case let .key(keyCode, down, flags):
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
                    throw ComputerUseError.message("Failed to create key event; nothing was sent.")
                }
                event.flags = flags
                return .event(event)
            case let .wait(seconds):
                return .wait(seconds)
            }
        }

        for item in prepared {
            switch item {
            case .event(let event):
                event.postToPid(pid)
            case .wait(let seconds):
                Thread.sleep(forTimeInterval: seconds)
            }
        }
    }
}
