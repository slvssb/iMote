import SwiftUI
import UIKit

struct HiddenTextInputView: UIViewRepresentable {
    var isActive: Bool
    var activeModifiers: Set<RemoteModifier>
    var onCharacter: (Character) -> Void
    var onBackspace: () -> Void
    var onReturn: () -> Void
    var onToggleModifier: (RemoteModifier) -> Void
    var onSpecialKey: (KeyboardNamedKey) -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HiddenTextInputView

        init(parent: HiddenTextInputView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            moveCursorToEnd(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            moveCursorToEnd(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let currentText = textView.text ?? ""
            let nsCurrentText = currentText as NSString
            guard range.location >= 0, range.location + range.length <= nsCurrentText.length else {
                return false
            }

            let touchesTail = (range.location + range.length) == nsCurrentText.length
            guard touchesTail else {
                if let backspaceTextView = textView as? BackspaceTextView {
                    backspaceTextView.moveCursorToEnd()
                }
                return false
            }

            var effectiveRange = range
            if range.length == 0, text.count > 1 {
                let trailingWord = trailingWordAtTail(in: currentText)
                if trailingWord.isEmpty == false,
                   text.hasPrefix(trailingWord) {
                    effectiveRange = NSRange(
                        location: nsCurrentText.length - trailingWord.utf16.count,
                        length: trailingWord.utf16.count
                    )
                }
            }

            for _ in 0..<effectiveRange.length {
                parent.onBackspace()
            }

            for character in text {
                if character == "\n" {
                    parent.onReturn()
                } else {
                    parent.onCharacter(character)
                }
            }

            let nextText = nsCurrentText.replacingCharacters(in: effectiveRange, with: text)
            if let backspaceTextView = textView as? BackspaceTextView {
                backspaceTextView.setPreviewText(nextText)
                backspaceTextView.scheduleAutoClear()
            }

            return false
        }

        private func trailingWordAtTail(in value: String) -> String {
            var collected: [Character] = []
            for character in value.reversed() {
                if character.isWhitespace {
                    break
                }
                collected.append(character)
            }
            return String(collected.reversed())
        }

        private func moveCursorToEnd(_ textView: UITextView) {
            (textView as? BackspaceTextView)?.moveCursorToEnd()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> BackspaceTextView {
        let field = BackspaceTextView()
        let accessory = KeyboardAccessoryView()
        let refocus: () -> Void = {
            DispatchQueue.main.async {
                field.lockFocus = true
                field.becomeFirstResponder()
                field.moveCursorToEnd()
            }
        }
        field.delegate = context.coordinator
        field.keyboardToolbar = accessory
        field.inputAccessoryView = accessory
        field.backspaceWhenEmptyHandler = {
            context.coordinator.parent.onBackspace()
            refocus()
        }
        field.autocorrectionType = .yes
        field.autocapitalizationType = .none
        field.spellCheckingType = .yes
        field.smartDashesType = .default
        field.smartQuotesType = .default
        field.smartInsertDeleteType = .default
        field.keyboardType = .default
        field.returnKeyType = .default
        field.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        field.textAlignment = .left
        field.tintColor = .clear
        field.textColor = .label
        field.backgroundColor = .clear
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        field.textContainer.lineBreakMode = .byWordWrapping
        field.alwaysBounceHorizontal = false
        field.showsHorizontalScrollIndicator = false
        field.isScrollEnabled = true

        accessory.onModifierTapped = { modifier in
            context.coordinator.parent.onToggleModifier(modifier)
            refocus()
        }
        accessory.onSpecialKeyTapped = { key in
            if key == .backspace {
                field.removeLastPreviewCharacter()
                context.coordinator.parent.onBackspace()
            } else if key == .enter {
                context.coordinator.parent.onReturn()
                field.appendPreview("\n")
            } else if key == .space {
                context.coordinator.parent.onSpecialKey(key)
                field.appendPreview(" ")
            } else {
                context.coordinator.parent.onSpecialKey(key)
            }
            field.scheduleAutoClear()
            refocus()
        }
        accessory.updateModifierState(activeModifiers)

        return field
    }

    func updateUIView(_ uiView: BackspaceTextView, context: Context) {
        context.coordinator.parent = self
        uiView.keyboardToolbar?.updateModifierState(activeModifiers)
        uiView.lockFocus = isActive

        if isActive && uiView.isFirstResponder == false {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
                uiView.moveCursorToEnd()
            }
        } else if isActive == false && uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.resignFirstResponder()
            }
        }
    }
}

final class BackspaceTextView: UITextView {
    var backspaceWhenEmptyHandler: (() -> Void)?
    weak var keyboardToolbar: KeyboardAccessoryView?
    var lockFocus = false
    private var clearWorkItem: DispatchWorkItem?

    override func deleteBackward() {
        if (text ?? "").isEmpty {
            backspaceWhenEmptyHandler?()
        }
        super.deleteBackward()
        scheduleAutoClear()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func resignFirstResponder() -> Bool {
        if lockFocus {
            return false
        }
        return super.resignFirstResponder()
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        []
    }

    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        endOfDocument
    }

    func moveCursorToEnd() {
        let length = (text ?? "").utf16.count
        selectedRange = NSRange(location: length, length: 0)
    }

    func appendPreview(_ value: String) {
        let current = text ?? ""
        text = current + value
        moveCursorToEnd()
    }

    func setPreviewText(_ value: String) {
        text = value
        moveCursorToEnd()
    }

    func removeLastPreviewCharacter() {
        guard var current = text, current.isEmpty == false else { return }
        current.removeLast()
        text = current
        moveCursorToEnd()
    }

    func scheduleAutoClear() {
        clearWorkItem?.cancel()
    }
}

final class KeyboardAccessoryView: UIInputView {
    var onModifierTapped: ((RemoteModifier) -> Void)?
    var onSpecialKeyTapped: ((KeyboardNamedKey) -> Void)?

    private var modifierButtons: [RemoteModifier: UIButton] = [:]
    private let accessoryHeight: CGFloat = 96

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: accessoryHeight)
    }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        let initialFrame = CGRect(x: 0, y: 0, width: 0, height: accessoryHeight)
        super.init(frame: initialFrame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = false
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: accessoryHeight)
    }

    func updateModifierState(_ active: Set<RemoteModifier>) {
        for (modifier, button) in modifierButtons {
            let isActive = active.contains(modifier)
            button.configuration = modifierConfiguration(
                title: button.configuration?.title ?? "",
                active: isActive
            )
        }
    }

    private func setup() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 12
        blur.clipsToBounds = true
        addSubview(blur)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            blur.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -8),
            root.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -8)
        ])

        let modifierRow = UIStackView()
        modifierRow.axis = .horizontal
        modifierRow.alignment = .fill
        modifierRow.distribution = .fillEqually
        modifierRow.spacing = 6

        let modifiers: [(RemoteModifier, String)] = [
            (.command, "⌘"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.control, "⌃")
        ]

        for (modifier, title) in modifiers {
            let button = UIButton(type: .system)
            button.configuration = modifierConfiguration(title: title, active: false)
            button.addAction(UIAction { [weak self] _ in
                self?.onModifierTapped?(modifier)
            }, for: .touchUpInside)
            modifierButtons[modifier] = button
            modifierRow.addArrangedSubview(button)
        }

        let specialRow = UIStackView()
        specialRow.axis = .horizontal
        specialRow.alignment = .fill
        specialRow.distribution = .fillEqually
        specialRow.spacing = 6

        let specialKeys: [(KeyboardNamedKey, String)] = [
            (.backspace, "⌫"),
            (.enter, "↩"),
            (.space, "␣"),
            (.leftArrow, "←"),
            (.upArrow, "↑"),
            (.downArrow, "↓"),
            (.rightArrow, "→")
        ]

        for (key, title) in specialKeys {
            let button = UIButton(type: .system)
            button.configuration = specialConfiguration(title: title)
            button.addAction(UIAction { [weak self] _ in
                self?.onSpecialKeyTapped?(key)
            }, for: .touchUpInside)
            specialRow.addArrangedSubview(button)
        }

        root.addArrangedSubview(modifierRow)
        root.addArrangedSubview(specialRow)
    }

    private func modifierConfiguration(title: String, active: Bool) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = active ? .systemGreen : UIColor.systemGray3.withAlphaComponent(0.65)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        return config
    }

    private func specialConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.78)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        return config
    }
}
