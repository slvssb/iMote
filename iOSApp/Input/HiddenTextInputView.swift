import SwiftUI
import UIKit
import QuartzCore

struct HiddenTextInputView: UIViewRepresentable {
    var isActive: Bool
    var activeModifiers: Set<RemoteModifier>
    var onCharacter: (Character) -> Void
    var onBackspace: () -> Void
    var onReturn: () -> Void
    var onToggleModifier: (RemoteModifier) -> Void
    var onSpecialKey: (KeyboardNamedKey) -> Void
    var keyRepeatInterval: TimeInterval

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HiddenTextInputView
        private var lastAcceptedEditSignature: String?
        private var lastAcceptedEditTime: CFTimeInterval = 0

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

            if shouldSkipDuplicateEdit(range: range, replacementText: text) {
                return false
            }

            let trailingWord = trailingWordAtTail(in: currentText)
            let suggestionStem = suggestionLeadingWord(in: text)

            if shouldSkipRepeatedSuggestionInsert(
                range: range,
                replacementText: text,
                trailingWord: trailingWord,
                suggestionStem: suggestionStem,
                touchesTail: touchesTail
            ) {
                return false
            }

            var effectiveRange = range
            if suggestionCanReplaceTrailingWord(
                trailingWord: trailingWord,
                suggestionStem: suggestionStem,
                touchesTail: touchesTail
            ) {
                effectiveRange = NSRange(
                    location: nsCurrentText.length - trailingWord.utf16.count,
                    length: trailingWord.utf16.count
                )
            }

            for _ in 0..<effectiveRange.length {
                parent.onBackspace()
            }

            let containsReturn = text.contains("\n")
            for character in text {
                if character == "\n" {
                    parent.onReturn()
                } else {
                    parent.onCharacter(character)
                }
            }

            let nextText = nsCurrentText.replacingCharacters(in: effectiveRange, with: text)
            if let backspaceTextView = textView as? BackspaceTextView {
                if containsReturn && parent.activeModifiers.contains(.shift) == false {
                    backspaceTextView.clearPreview()
                } else {
                    backspaceTextView.setPreviewText(nextText)
                }
            }

            return false
        }

        private func shouldSkipDuplicateEdit(range: NSRange, replacementText: String) -> Bool {
            let signature = "\(range.location):\(range.length):\(replacementText)"
            let now = CACurrentMediaTime()
            let isDuplicate = signature == lastAcceptedEditSignature && (now - lastAcceptedEditTime) < 0.12

            if isDuplicate == false {
                lastAcceptedEditSignature = signature
                lastAcceptedEditTime = now
            }

            return isDuplicate
        }

        private func shouldSkipRepeatedSuggestionInsert(
            range: NSRange,
            replacementText: String,
            trailingWord: String,
            suggestionStem: String,
            touchesTail: Bool
        ) -> Bool {
            guard touchesTail, range.length == 0, replacementText.count > 1 else { return false }
            guard trailingWord.isEmpty == false, suggestionStem.isEmpty == false else { return false }
            return trailingWord.caseInsensitiveCompare(suggestionStem) == .orderedSame
        }

        private func suggestionCanReplaceTrailingWord(
            trailingWord: String,
            suggestionStem: String,
            touchesTail: Bool
        ) -> Bool {
            guard touchesTail, trailingWord.isEmpty == false, suggestionStem.isEmpty == false else {
                return false
            }
            return suggestionStem.lowercased().hasPrefix(trailingWord.lowercased())
        }

        private func suggestionLeadingWord(in replacementText: String) -> String {
            let trimmed = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return "" }

            var collected: [Character] = []
            for character in trimmed {
                if character.isWhitespace || character == "\n" {
                    break
                }
                collected.append(character)
            }
            return String(collected)
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
        accessory.keyRepeatInterval = keyRepeatInterval
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
        field.textColor = .white
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
                if context.coordinator.parent.activeModifiers.contains(.shift) {
                    field.appendPreview("\n")
                } else {
                    field.clearPreview()
                }
            } else if key == .space {
                context.coordinator.parent.onSpecialKey(key)
                field.appendPreview(" ")
            } else {
                context.coordinator.parent.onSpecialKey(key)
            }
            refocus()
        }
        accessory.updateModifierState(activeModifiers)

        field.prewarmKeyboardIfNeeded()

        return field
    }

    func updateUIView(_ uiView: BackspaceTextView, context: Context) {
        context.coordinator.parent = self
        uiView.keyboardToolbar?.updateModifierState(activeModifiers)
        uiView.keyboardToolbar?.keyRepeatInterval = keyRepeatInterval
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
    private static var didPrewarmKeyboard = false

    var backspaceWhenEmptyHandler: (() -> Void)?
    weak var keyboardToolbar: KeyboardAccessoryView?
    var lockFocus = false
    private var clearWorkItem: DispatchWorkItem?

    override func deleteBackward() {
        if (text ?? "").isEmpty {
            backspaceWhenEmptyHandler?()
        }
        super.deleteBackward()
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

    func clearPreview() {
        text = ""
        moveCursorToEnd()
        clearWorkItem?.cancel()
    }

    func scheduleAutoClear() {
        clearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearPreview()
        }
        clearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    func prewarmKeyboardIfNeeded() {
        guard Self.didPrewarmKeyboard == false else { return }
        Self.didPrewarmKeyboard = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previousLockFocus = self.lockFocus
            self.lockFocus = false
            _ = self.becomeFirstResponder()
            _ = self.resignFirstResponder()
            self.lockFocus = previousLockFocus
        }
    }
}

final class KeyboardAccessoryView: UIInputView {
    var onModifierTapped: ((RemoteModifier) -> Void)?
    var onSpecialKeyTapped: ((KeyboardNamedKey) -> Void)?
    var keyRepeatInterval: TimeInterval = 0.08

    private var modifierButtons: [RemoteModifier: UIButton] = [:]
    private var specialButtonMap: [UIButton: KeyboardNamedKey] = [:]
    private var repeatTimer: Timer?
    private weak var repeatButton: UIButton?
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
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
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
            specialButtonMap[button] = key
            button.addTarget(self, action: #selector(handleRepeatTouchDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(handleRepeatTouchUp(_:)), for: .touchUpInside)
            button.addTarget(self, action: #selector(handleRepeatTouchUp(_:)), for: .touchUpOutside)
            button.addTarget(self, action: #selector(handleRepeatTouchUp(_:)), for: .touchCancel)
            specialRow.addArrangedSubview(button)
        }

        root.addArrangedSubview(modifierRow)
        root.addArrangedSubview(specialRow)
    }

    @objc private func handleRepeatTouchDown(_ sender: UIButton) {
        guard let key = specialButtonMap[sender], isRepeatableKey(key) else { return }
        repeatButton = sender
        repeatTimer?.invalidate()

        let timer = Timer(timeInterval: 0.35, target: self, selector: #selector(handleInitialRepeatFire), userInfo: nil, repeats: false)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleRepeatTouchUp(_ sender: UIButton) {
        guard repeatButton === sender else { return }
        repeatButton = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @objc private func handleInitialRepeatFire() {
        guard let repeatButton,
              let repeatingKey = specialButtonMap[repeatButton] else {
            repeatTimer?.invalidate()
            repeatTimer = nil
            return
        }

        onSpecialKeyTapped?(repeatingKey)
        repeatTimer?.invalidate()

        let timer = Timer(timeInterval: keyRepeatInterval, target: self, selector: #selector(handleRepeatFire), userInfo: nil, repeats: true)
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleRepeatFire() {
        guard let repeatButton,
              let repeatingKey = specialButtonMap[repeatButton] else {
            repeatTimer?.invalidate()
            repeatTimer = nil
            return
        }
        onSpecialKeyTapped?(repeatingKey)
    }

    private func isRepeatableKey(_ key: KeyboardNamedKey) -> Bool {
        switch key {
        case .backspace, .leftArrow, .rightArrow, .upArrow, .downArrow:
            return true
        default:
            return false
        }
    }

    private func modifierConfiguration(title: String, active: Bool) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = active ? UIColor(white: 0.34, alpha: 1) : UIColor(white: 0.20, alpha: 0.95)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        return config
    }

    private func specialConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.30, alpha: 0.95)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        return config
    }
}
