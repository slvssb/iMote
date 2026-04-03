import SwiftUI

struct MacStyleKeyboardView: View {
    private struct KeySpec: Identifiable {
        enum Kind {
            case character(String)
            case named(KeyboardNamedKey)
            case modifier(RemoteModifier)
        }

        let id = UUID()
        let label: String
        let kind: Kind
        let widthUnits: CGFloat
    }

    var showFunctionRow: Bool
    var activeModifiers: Set<RemoteModifier>
    var onCharacter: (Character) -> Void
    var onNamedKey: (KeyboardNamedKey) -> Void
    var onToggleModifier: (RemoteModifier) -> Void

    private let spacing: CGFloat = 5
    private let keyHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: spacing) {
            if showFunctionRow {
                keyRow(functionRow)
            }
            keyRow(numberRow)
            keyRow(qwertyRow)
            keyRow(homeRow)
            keyRow(bottomRow)
            keyRow(modifierRow)
        }
    }

    private var functionRow: [KeySpec] {
        [
            key("esc", .named(.escape), 1.4),
            key("F1", .named(.f1)), key("F2", .named(.f2)), key("F3", .named(.f3)), key("F4", .named(.f4)),
            key("F5", .named(.f5)), key("F6", .named(.f6)), key("F7", .named(.f7)), key("F8", .named(.f8)),
            key("F9", .named(.f9)), key("F10", .named(.f10)), key("F11", .named(.f11)), key("F12", .named(.f12))
        ]
    }

    private var numberRow: [KeySpec] {
        [
            key("`", .character("`")), key("1", .character("1")), key("2", .character("2")), key("3", .character("3")),
            key("4", .character("4")), key("5", .character("5")), key("6", .character("6")), key("7", .character("7")),
            key("8", .character("8")), key("9", .character("9")), key("0", .character("0")),
            key("-", .character("-")), key("=", .character("=")),
            key("delete", .named(.backspace), 1.8)
        ]
    }

    private var qwertyRow: [KeySpec] {
        [
            key("tab", .named(.tab), 1.5),
            key("q", .character("q")), key("w", .character("w")), key("e", .character("e")), key("r", .character("r")),
            key("t", .character("t")), key("y", .character("y")), key("u", .character("u")), key("i", .character("i")),
            key("o", .character("o")), key("p", .character("p")), key("[", .character("[")), key("]", .character("]")),
            key("\\", .character("\\"), 1.2)
        ]
    }

    private var homeRow: [KeySpec] {
        [
            key("caps", .modifier(.shift), 1.7),
            key("a", .character("a")), key("s", .character("s")), key("d", .character("d")), key("f", .character("f")),
            key("g", .character("g")), key("h", .character("h")), key("j", .character("j")), key("k", .character("k")),
            key("l", .character("l")), key(";", .character(";")), key("'", .character("'")),
            key("return", .named(.enter), 1.9)
        ]
    }

    private var bottomRow: [KeySpec] {
        [
            key("shift", .modifier(.shift), 2.1),
            key("z", .character("z")), key("x", .character("x")), key("c", .character("c")), key("v", .character("v")),
            key("b", .character("b")), key("n", .character("n")), key("m", .character("m")),
            key(",", .character(",")), key(".", .character(".")), key("/", .character("/")),
            key("shift", .modifier(.shift), 2.1)
        ]
    }

    private var modifierRow: [KeySpec] {
        [
            key("control", .modifier(.control), 1.5),
            key("option", .modifier(.option), 1.4),
            key("command", .modifier(.command), 1.8),
            key("space", .named(.space), 4.8),
            key("command", .modifier(.command), 1.8),
            key("option", .modifier(.option), 1.4),
            key("⌦", .named(.forwardDelete), 1.1),
            key("◀", .named(.leftArrow), 1.0),
            key("▲", .named(.upArrow), 1.0),
            key("▼", .named(.downArrow), 1.0),
            key("▶", .named(.rightArrow), 1.0)
        ]
    }

    private func key(_ label: String, _ kind: KeySpec.Kind, _ widthUnits: CGFloat = 1) -> KeySpec {
        KeySpec(label: label, kind: kind, widthUnits: widthUnits)
    }

    @ViewBuilder
    private func keyRow(_ keys: [KeySpec]) -> some View {
        GeometryReader { proxy in
            let totalUnits = keys.reduce(CGFloat(0)) { $0 + $1.widthUnits }
            let totalSpacing = CGFloat(max(keys.count - 1, 0)) * spacing
            let baseUnit = max((proxy.size.width - totalSpacing) / max(totalUnits, 1), 1)

            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    keyButton(for: key)
                        .frame(width: baseUnit * key.widthUnits, height: keyHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: keyHeight)
    }

    @ViewBuilder
    private func keyButton(for key: KeySpec) -> some View {
        switch key.kind {
        case .character(let value):
            Button(displayLabel(for: value)) {
                guard let character = displayLabel(for: value).first else { return }
                onCharacter(character)
            }
            .buttonStyle(keyStyle(active: false))
        case .named(let named):
            Button(key.label) {
                onNamedKey(named)
            }
            .buttonStyle(keyStyle(active: false))
        case .modifier(let modifier):
            Button(key.label) {
                onToggleModifier(modifier)
            }
            .buttonStyle(keyStyle(active: activeModifiers.contains(modifier)))
        }
    }

    private func displayLabel(for value: String) -> String {
        if activeModifiers.contains(.shift) {
            return value.uppercased()
        }
        return value
    }

    private func keyStyle(active: Bool) -> some ButtonStyle {
        MacKeyboardKeyStyle(isActive: active)
    }
}

private struct MacKeyboardKeyStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.32) : Color.white.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(configuration.isPressed ? 0.55 : 0.25), lineWidth: 0.8)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
