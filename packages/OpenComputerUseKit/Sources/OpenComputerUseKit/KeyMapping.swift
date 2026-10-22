import Carbon.HIToolbox
import CoreGraphics
import Foundation

public struct ParsedKeyPress: Sendable {
    public struct Modifier: Sendable {
        public let flag: CGEventFlags
        public let keyCode: CGKeyCode
    }

    public let keyCode: CGKeyCode
    public let modifiers: [Modifier]
    public let displayValue: String
    /// The layout types `displayValue` only with shift (`?` on a US layout), so
    /// `modifiers` carries a shift the character already implies.
    public let shiftedCharacter: Bool
}

public enum KeyPressParser {
    public static func parse(_ specification: String) throws -> ParsedKeyPress {
        let tokens = specification
            .split(separator: "+")
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }

        guard let keyToken = tokens.last else {
            throw ComputerUseError.invalidArguments("key specification is empty")
        }

        var modifiers = try tokens.dropLast().map(parseModifier(_:))
        let keyCode: CGKeyCode
        var shiftedCharacter = false
        if let named = keyCodeMap[keyToken] {
            keyCode = named
        } else if keyToken.count == 1, let key = layoutKeys[keyToken.first!] {
            // Any character the keyboard layout can type: its key, with shift when it needs it.
            keyCode = key.code
            shiftedCharacter = key.shift
            if key.shift, !modifiers.contains(where: { $0.flag == .maskShift }) {
                modifiers.append(ParsedKeyPress.Modifier(flag: .maskShift, keyCode: CGKeyCode(kVK_Shift)))
            }
        } else {
            throw ComputerUseError.invalidArguments("unsupported key '\(specification)'")
        }

        return ParsedKeyPress(
            keyCode: keyCode,
            modifiers: modifiers,
            displayValue: keyToken,
            shiftedCharacter: shiftedCharacter
        )
    }

    /// Read at each lookup, so a layout the person switches to mid-session is followed.
    private static var layoutKeys: [Character: (code: CGKeyCode, shift: Bool)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return [:]
        }
        return characterKeys(in: source)
    }

    /// Every character `layout` types with one main-keyboard key, plain or shifted
    /// (a plain key wins), so a key needs no name of its own in `keyCodeMap`.
    static func characterKeys(in layout: TISInputSource) -> [Character: (code: CGKeyCode, shift: Bool)] {
        var table: [Character: (code: CGKeyCode, shift: Bool)] = [:]
        guard let pointer = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else {
            return table
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        data.withUnsafeBytes { raw in
            guard let keyboard = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                // The keypad keeps its `kp_*` names: `*` is shift+8 on a US layout, not the keypad key.
                for code in 0..<128 where !(kVK_ANSI_KeypadDecimal...kVK_ANSI_Keypad9).contains(code) {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let modifiers: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
                    let status = UCKeyTranslate(keyboard, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                    guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let character = Character(scalar)
                    if table[character] == nil {
                        table[character] = (CGKeyCode(code), shift)
                    }
                }
            }
        }
        return table
    }

    private static func parseModifier(_ token: String) throws -> ParsedKeyPress.Modifier {
        switch token {
        case "cmd", "command", "super", "meta":
            return ParsedKeyPress.Modifier(flag: .maskCommand, keyCode: CGKeyCode(kVK_Command))
        case "shift":
            return ParsedKeyPress.Modifier(flag: .maskShift, keyCode: CGKeyCode(kVK_Shift))
        case "option", "alt":
            return ParsedKeyPress.Modifier(flag: .maskAlternate, keyCode: CGKeyCode(kVK_Option))
        case "control", "ctrl":
            return ParsedKeyPress.Modifier(flag: .maskControl, keyCode: CGKeyCode(kVK_Control))
        default:
            throw ComputerUseError.invalidArguments("unsupported modifier '\(token)'")
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static let keyCodeMap: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A),
        "b": CGKeyCode(kVK_ANSI_B),
        "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D),
        "e": CGKeyCode(kVK_ANSI_E),
        "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G),
        "h": CGKeyCode(kVK_ANSI_H),
        "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J),
        "k": CGKeyCode(kVK_ANSI_K),
        "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M),
        "n": CGKeyCode(kVK_ANSI_N),
        "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P),
        "q": CGKeyCode(kVK_ANSI_Q),
        "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S),
        "t": CGKeyCode(kVK_ANSI_T),
        "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V),
        "w": CGKeyCode(kVK_ANSI_W),
        "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y),
        "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0),
        "1": CGKeyCode(kVK_ANSI_1),
        "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4),
        "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6),
        "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9),
        "return": CGKeyCode(kVK_Return),
        "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab),
        "space": CGKeyCode(kVK_Space),
        "spacebar": CGKeyCode(kVK_Space),
        "escape": CGKeyCode(kVK_Escape),
        "esc": CGKeyCode(kVK_Escape),
        "backspace": CGKeyCode(kVK_Delete),
        "delete": CGKeyCode(kVK_Delete),
        "del": CGKeyCode(kVK_ForwardDelete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete),
        "insert": CGKeyCode(kVK_Help),
        "up": CGKeyCode(kVK_UpArrow),
        "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow),
        "right": CGKeyCode(kVK_RightArrow),
        "home": CGKeyCode(kVK_Home),
        "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp),
        "page_up": CGKeyCode(kVK_PageUp),
        "prior": CGKeyCode(kVK_PageUp),
        "pagedown": CGKeyCode(kVK_PageDown),
        "page_down": CGKeyCode(kVK_PageDown),
        "next": CGKeyCode(kVK_PageDown),
        "caps_lock": CGKeyCode(kVK_CapsLock),
        "f1": CGKeyCode(kVK_F1),
        "f2": CGKeyCode(kVK_F2),
        "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4),
        "f5": CGKeyCode(kVK_F5),
        "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7),
        "f8": CGKeyCode(kVK_F8),
        "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10),
        "f11": CGKeyCode(kVK_F11),
        "f12": CGKeyCode(kVK_F12),
        "kp_0": CGKeyCode(kVK_ANSI_Keypad0),
        "kp_1": CGKeyCode(kVK_ANSI_Keypad1),
        "kp_2": CGKeyCode(kVK_ANSI_Keypad2),
        "kp_3": CGKeyCode(kVK_ANSI_Keypad3),
        "kp_4": CGKeyCode(kVK_ANSI_Keypad4),
        "kp_5": CGKeyCode(kVK_ANSI_Keypad5),
        "kp_6": CGKeyCode(kVK_ANSI_Keypad6),
        "kp_7": CGKeyCode(kVK_ANSI_Keypad7),
        "kp_8": CGKeyCode(kVK_ANSI_Keypad8),
        "kp_9": CGKeyCode(kVK_ANSI_Keypad9),
        "kp_enter": CGKeyCode(kVK_ANSI_KeypadEnter),
        "kp_equal": CGKeyCode(kVK_ANSI_KeypadEquals),
        "kp_multiply": CGKeyCode(kVK_ANSI_KeypadMultiply),
        "kp_add": CGKeyCode(kVK_ANSI_KeypadPlus),
        "kp_subtract": CGKeyCode(kVK_ANSI_KeypadMinus),
        "kp_decimal": CGKeyCode(kVK_ANSI_KeypadDecimal),
        "kp_divide": CGKeyCode(kVK_ANSI_KeypadDivide),
        "kp_delete": CGKeyCode(kVK_ANSI_KeypadDecimal),
        "kp_home": CGKeyCode(kVK_Home),
        "kp_left": CGKeyCode(kVK_LeftArrow),
        "kp_up": CGKeyCode(kVK_UpArrow),
        "kp_right": CGKeyCode(kVK_RightArrow),
        "kp_down": CGKeyCode(kVK_DownArrow),
        "kp_prior": CGKeyCode(kVK_PageUp),
        "kp_page_up": CGKeyCode(kVK_PageUp),
        "kp_next": CGKeyCode(kVK_PageDown),
        "kp_page_down": CGKeyCode(kVK_PageDown),
        "kp_end": CGKeyCode(kVK_End),
        "kp_insert": CGKeyCode(kVK_Help),
    ]
}
