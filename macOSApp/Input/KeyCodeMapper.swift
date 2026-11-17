import Carbon
import CoreGraphics
import Foundation

struct ResolvedKeystroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

struct KeyCodeMapper {
    private let layoutTable = LayoutKeyTable()
    private let namedKeys: [String: CGKeyCode] = {
        var result: [String: CGKeyCode] = [:]

        let aliases: [(String, CGKeyCode)] = [
            (RemoteModifier.command.rawValue, 55),
            (RemoteModifier.option.rawValue, 58),
            (RemoteModifier.shift.rawValue, 56),
            (RemoteModifier.control.rawValue, 59),
            (KeyboardNamedKey.tab.rawValue, 48),
            (KeyboardNamedKey.space.rawValue, 49),
            (KeyboardNamedKey.backspace.rawValue, 51),
            (KeyboardNamedKey.forwardDelete.rawValue, 117),
            (KeyboardNamedKey.enter.rawValue, 36),
            (KeyboardNamedKey.escape.rawValue, 53),
            (KeyboardNamedKey.f1.rawValue, 122),
            (KeyboardNamedKey.f2.rawValue, 120),
            (KeyboardNamedKey.f3.rawValue, 99),
            (KeyboardNamedKey.f4.rawValue, 118),
            (KeyboardNamedKey.f5.rawValue, 96),
            (KeyboardNamedKey.f6.rawValue, 97),
            (KeyboardNamedKey.f7.rawValue, 98),
            (KeyboardNamedKey.f8.rawValue, 100),
            (KeyboardNamedKey.f9.rawValue, 101),
            (KeyboardNamedKey.f10.rawValue, 109),
            (KeyboardNamedKey.f11.rawValue, 103),
            (KeyboardNamedKey.f12.rawValue, 111),
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

    func resolve(key: String, modifiers: [RemoteModifier]) -> ResolvedKeystroke? {
        let compact = normalizedKey(for: key)
        if let code = namedKeys[compact] ?? namedKeys[compact.lowercased()] {
            return ResolvedKeystroke(keyCode: code, flags: eventFlags(for: modifiers))
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first else { return nil }
        guard let match = layoutTable.lookup(character) else { return nil }
        var flags = eventFlags(for: modifiers)
        if match.needsShift {
            flags.insert(.maskShift)
        }
        return ResolvedKeystroke(keyCode: match.keyCode, flags: flags)
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

private final class LayoutKeyTable {
    struct Match {
        let keyCode: CGKeyCode
        let needsShift: Bool
    }

    private var sourceID = ""
    private var unshifted: [Character: CGKeyCode] = [:]
    private var shifted: [Character: CGKeyCode] = [:]
    private var didLoadLayout = false

    func lookup(_ character: Character) -> Match? {
        refreshIfNeeded()
        if let code = unshifted[character] {
            return Match(keyCode: code, needsShift: false)
        }
        if let code = shifted[character] {
            return Match(keyCode: code, needsShift: true)
        }
        return nil
    }

    private func refreshIfNeeded() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            didLoadLayout = false
            unshifted.removeAll()
            shifted.removeAll()
            return
        }
        let currentID: String
        if let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            currentID = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        } else {
            currentID = ""
        }
        guard currentID != sourceID || didLoadLayout == false else { return }
        sourceID = currentID
        rebuild(source: source)
    }

    private func rebuild(source: TISInputSource) {
        unshifted.removeAll()
        shifted.removeAll()
        guard let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            didLoadLayout = false
            return
        }
        let data = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else {
            didLoadLayout = false
            return
        }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        let shiftModifier = UInt32((Int(shiftKey) >> 8) & 0xFF)

        for code in 0..<128 {
            let keyCode = CGKeyCode(code)
            if let plain = translate(layout, keyCode: UInt16(code), modifier: 0, keyboardType: keyboardType),
               plain.count == 1, let character = plain.first, unshifted[character] == nil {
                unshifted[character] = keyCode
            }
            if let shiftedText = translate(layout, keyCode: UInt16(code), modifier: shiftModifier, keyboardType: keyboardType),
               shiftedText.count == 1, let character = shiftedText.first, self.shifted[character] == nil {
                self.shifted[character] = keyCode
            }
        }
        didLoadLayout = true
    }

    private func translate(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        keyCode: UInt16,
        modifier: UInt32,
        keyboardType: UInt32
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            modifier,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
