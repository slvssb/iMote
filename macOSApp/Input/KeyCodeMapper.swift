import CoreGraphics
import Foundation

struct KeyCodeMapper {
    private let mapping: [String: CGKeyCode] = {
        var result: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "`": 50
        ]

        let aliases: [(String, CGKeyCode)] = [
            (KeyboardNamedKey.tab.rawValue, 48),
            (KeyboardNamedKey.space.rawValue, 49),
            (KeyboardNamedKey.backspace.rawValue, 51),
            (KeyboardNamedKey.enter.rawValue, 36),
            (KeyboardNamedKey.escape.rawValue, 53),
            (KeyboardNamedKey.leftArrow.rawValue, 123),
            (KeyboardNamedKey.rightArrow.rawValue, 124),
            (KeyboardNamedKey.downArrow.rawValue, 125),
            (KeyboardNamedKey.upArrow.rawValue, 126)
        ]

        for (key, code) in aliases {
            result[key] = code
            result[key.lowercased()] = code
        }

        let extraArrowAliases: [String: CGKeyCode] = [
            "left": 123, "arrowleft": 123, "left_arrow": 123, "left-arrow": 123, "uiKeyInputLeftArrow".lowercased(): 123, "←": 123,
            "right": 124, "arrowright": 124, "right_arrow": 124, "right-arrow": 124, "uiKeyInputRightArrow".lowercased(): 124, "→": 124,
            "down": 125, "arrowdown": 125, "down_arrow": 125, "down-arrow": 125, "uiKeyInputDownArrow".lowercased(): 125, "↓": 125,
            "up": 126, "arrowup": 126, "up_arrow": 126, "up-arrow": 126, "uiKeyInputUpArrow".lowercased(): 126, "↑": 126
        ]
        for (key, code) in extraArrowAliases {
            result[key] = code
            result[key.lowercased()] = code
        }

        return result
    }()

    func normalizedKey(for key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }

    func keyCode(for key: String) -> CGKeyCode? {
        let normalized = normalizedKey(for: key)
        if let direct = mapping[normalized] {
            return direct
        }
        return mapping[normalized.lowercased()]
    }

    func eventFlags(for modifiers: [RemoteModifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .option:
                flags.insert(.maskAlternate)
            case .shift:
                flags.insert(.maskShift)
            case .control:
                flags.insert(.maskControl)
            }
        }
        return flags
    }
}
