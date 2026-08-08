import Foundation
import CoreGraphics

/// Translation between macOS virtual key codes and the key identifiers used by
/// Mechvibes sound packs.
///
/// There are two pack generations in the wild and they name keys differently:
///
///   * v2 (MechvibesDX) uses W3C `KeyboardEvent.code` strings -- "KeyA", "Digit1".
///   * v1 (original Mechvibes) uses numeric scancodes inherited from iohook.
///
/// Both are keyed off the same macOS virtual key code on our side.
enum KeyCodes {

    /// macOS virtual key code -> W3C `KeyboardEvent.code`.
    static let toW3C: [UInt16: String] = [
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG",
        6: "KeyZ", 7: "KeyX", 8: "KeyC", 9: "KeyV", 10: "IntlBackslash",
        11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR",
        16: "KeyY", 17: "KeyT",
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6",
        23: "Digit5", 24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus",
        28: "Digit8", 29: "Digit0",
        30: "BracketRight", 31: "KeyO", 32: "KeyU", 33: "BracketLeft",
        34: "KeyI", 35: "KeyP", 36: "Enter", 37: "KeyL", 38: "KeyJ",
        39: "Quote", 40: "KeyK", 41: "Semicolon", 42: "Backslash",
        43: "Comma", 44: "Slash", 45: "KeyN", 46: "KeyM", 47: "Period",
        48: "Tab", 49: "Space", 50: "Backquote", 51: "Backspace",
        53: "Escape",
        // Modifiers.
        54: "MetaRight", 55: "MetaLeft", 56: "ShiftLeft", 57: "CapsLock",
        58: "AltLeft", 59: "ControlLeft", 60: "ShiftRight", 61: "AltRight",
        62: "ControlRight", 63: "Fn",
        // Keypad.
        65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd",
        71: "NumLock", 75: "NumpadDivide", 76: "NumpadEnter",
        78: "NumpadSubtract", 81: "NumpadEqual",
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3",
        86: "Numpad4", 87: "Numpad5", 88: "Numpad6", 89: "Numpad7",
        91: "Numpad8", 92: "Numpad9",
        // Function row.
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        // Navigation.
        114: "Insert", 115: "Home", 116: "PageUp", 117: "Delete",
        119: "End", 121: "PageDown",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
    ]

    /// macOS virtual key code -> candidate v1 numeric codes, best guess first.
    ///
    /// Codes 1...88 are the unambiguous PS/2 set-1 scancodes every v1 pack agrees
    /// on. The extended (0xE0-prefixed) keys are not agreed on -- different pack
    /// authors encoded the prefix as either 0xE000 or 0x0E00 -- so those keys list
    /// every plausible code and the loader takes whichever one the pack defines.
    static let toLegacy: [UInt16: [Int]] = [
        53: [1],
        18: [2], 19: [3], 20: [4], 21: [5], 23: [6], 22: [7],
        26: [8], 28: [9], 25: [10], 29: [11],
        27: [12], 24: [13], 51: [14], 48: [15],
        12: [16], 13: [17], 14: [18], 15: [19], 17: [20], 16: [21],
        32: [22], 34: [23], 31: [24], 35: [25], 33: [26], 30: [27],
        36: [28], 59: [29],
        0: [30], 1: [31], 2: [32], 3: [33], 5: [34], 4: [35],
        38: [36], 40: [37], 37: [38], 41: [39], 39: [40], 50: [41],
        56: [42], 42: [43],
        6: [44], 7: [45], 8: [46], 9: [47], 11: [48], 45: [49], 46: [50],
        43: [51], 47: [52], 44: [53], 60: [54],
        67: [55], 58: [56], 49: [57], 57: [58],
        122: [59], 120: [60], 99: [61], 118: [62], 96: [63],
        97: [64], 98: [65], 100: [66], 101: [67], 109: [68],
        71: [69], 107: [70],
        89: [71], 91: [72], 92: [73], 78: [74],
        86: [75], 87: [76], 88: [77], 69: [78],
        83: [79], 84: [80], 85: [81], 82: [82], 65: [83],
        103: [87], 111: [88],
        // Extended keys -- ambiguous encodings.
        76: [3612, 57372],
        62: [3613, 57373],
        75: [3637, 57397],
        61: [3640, 57400],
        115: [3655, 57415],
        116: [3657, 57417],
        119: [3663, 57423],
        121: [3665, 57425],
        114: [3666, 57426],
        117: [3667, 57427],
        55: [3675, 57435],
        54: [3676, 57436],
        126: [57416, 3656],
        123: [57419, 3659],
        124: [57421, 3661],
        125: [57424, 3664],
        105: [3639, 57399],
    ]

    /// Where to borrow a sound from when the pack has nothing for a key.
    ///
    /// Packs are recordings of real keyboards, usually PC ones, so gaps are
    /// normal: there is no Command key to record, and authors routinely capture
    /// only one of each modifier pair. Each key lists substitutes in descending
    /// order of physical similarity -- a key of roughly the same size and
    /// position, so the borrowed sample still sounds plausible.
    static let fallbacks: [UInt16: [UInt16]] = [
        55: [58, 59],          // MetaLeft     <- AltLeft, ControlLeft
        54: [61, 58, 59],      // MetaRight    <- AltRight, AltLeft, ControlLeft
        61: [58],              // AltRight     <- AltLeft
        62: [59],              // ControlRight <- ControlLeft
        63: [59, 58],          // Fn           <- ControlLeft, AltLeft
        10: [42],              // IntlBackslash<- Backslash
        81: [24],              // NumpadEqual  <- Equal
        // Extended function keys fall back along the row.
        105: [111], 107: [111], 113: [111], 106: [111],
        79: [111], 80: [111], 90: [111],
    ]

    /// Every key that has no sound and no useful fallback ends up here, so that
    /// nothing on the keyboard is ever silent.
    static let genericFallback: UInt16 = 0   // KeyA

    /// The function row on a Mac sends media events by default rather than
    /// F-key presses, under a separate event type. These are the
    /// `NX_KEYTYPE_*` codes carried in those events, mapped back to the F-key
    /// that physically occupies that position on an Apple keyboard -- so F11
    /// clicks with the F11 sample whether it is acting as "volume down" or not.
    static let mediaKeyToVirtualKey: [Int32: UInt16] = [
        3: 122,    // NX_KEYTYPE_BRIGHTNESS_DOWN -> F1
        2: 120,    // NX_KEYTYPE_BRIGHTNESS_UP   -> F2
        22: 96,    // NX_KEYTYPE_ILLUMINATION_DOWN -> F5
        21: 97,    // NX_KEYTYPE_ILLUMINATION_UP   -> F6
        18: 98,    // NX_KEYTYPE_PREVIOUS -> F7
        16: 100,   // NX_KEYTYPE_PLAY     -> F8
        17: 101,   // NX_KEYTYPE_NEXT     -> F9
        20: 98,    // NX_KEYTYPE_REWIND   -> F7
        19: 101,   // NX_KEYTYPE_FAST     -> F9
        7: 109,    // NX_KEYTYPE_MUTE       -> F10
        1: 103,    // NX_KEYTYPE_SOUND_DOWN -> F11
        0: 111,    // NX_KEYTYPE_SOUND_UP   -> F12
    ]

    /// Any function-row key Klik cannot identify borrows this one's sound, so an
    /// unrecognised media key is never silent.
    static let genericFunctionKey: UInt16 = 96   // F5

    /// `toW3C` inverted, built once.
    static let fromW3C: [String: UInt16] = {
        var map: [String: UInt16] = [:]
        for (virtualKey, code) in toW3C { map[code] = virtualKey }
        return map
    }()

    /// The key someone would press to type this character. Used to "play back"
    /// a word as keystrokes; anything untypeable is skipped.
    static func virtualKey(for character: Character) -> UInt16? {
        let lowered = Character(character.lowercased())
        let code: String
        if lowered.isLetter, lowered.isASCII {
            code = "Key" + String(lowered).uppercased()
        } else if lowered.isNumber, lowered.isASCII {
            code = "Digit" + String(lowered)
        } else if lowered == " " {
            code = "Space"
        } else {
            return nil
        }
        return fromW3C[code]
    }

    static func virtualKeys(for text: String) -> [UInt16] {
        text.compactMap { virtualKey(for: $0) }
    }

    /// Readable name for the key monitor in the menu.
    static func displayName(for virtualKey: UInt16) -> String {
        guard let code = toW3C[virtualKey] else { return "Key \(virtualKey)" }
        if code.hasPrefix("Key") { return String(code.dropFirst(3)) }
        if code.hasPrefix("Digit") { return String(code.dropFirst(5)) }

        switch code {
        case "MetaLeft": return "Command L"
        case "MetaRight": return "Command R"
        case "AltLeft": return "Option L"
        case "AltRight": return "Option R"
        case "ControlLeft": return "Control L"
        case "ControlRight": return "Control R"
        case "ShiftLeft": return "Shift L"
        case "ShiftRight": return "Shift R"
        case "Backquote": return "`"
        case "Minus": return "-"
        case "Equal": return "="
        case "BracketLeft": return "["
        case "BracketRight": return "]"
        case "Backslash": return "\\"
        case "Semicolon": return ";"
        case "Quote": return "'"
        case "Comma": return ","
        case "Period": return "."
        case "Slash": return "/"
        case "ArrowUp": return "Up"
        case "ArrowDown": return "Down"
        case "ArrowLeft": return "Left"
        case "ArrowRight": return "Right"
        default: return code
        }
    }

    /// Modifier keys report state changes through `flagsChanged` rather than
    /// key down/up, so press-vs-release has to be read out of the flag word.
    ///
    /// The left/right variants share the public masks (`.maskShift` covers both),
    /// so this uses the device-dependent bits, which do distinguish them.
    static func modifierIsDown(virtualKey: UInt16, flags: CGEventFlags) -> Bool? {
        let raw = flags.rawValue
        switch virtualKey {
        case 59: return raw & 0x0000_0001 != 0   // Control, left
        case 62: return raw & 0x0000_2000 != 0   // Control, right
        case 56: return raw & 0x0000_0002 != 0   // Shift, left
        case 60: return raw & 0x0000_0004 != 0   // Shift, right
        case 55: return raw & 0x0000_0008 != 0   // Command, left
        case 54: return raw & 0x0000_0010 != 0   // Command, right
        case 58: return raw & 0x0000_0020 != 0   // Option, left
        case 61: return raw & 0x0000_0040 != 0   // Option, right
        case 57: return flags.contains(.maskAlphaShift)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return nil
        }
    }
}
