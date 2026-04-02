import ApplicationServices
import Foundation

enum KeyboardInjectorError: LocalizedError {
    case accessibilityPermissionMissing
    case keyNotMapped(String)
    case eventBuildFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to inject keys."
        case let .keyNotMapped(key):
            return "No key mapping found for '\(key)'."
        case .eventBuildFailed:
            return "Unable to build keyboard or mouse event."
        }
    }
}

final class KeyboardInjector {
    private let mapper = KeyCodeMapper()
    private let permissionManager: AccessibilityPermissionManager

    init(permissionManager: AccessibilityPermissionManager) {
        self.permissionManager = permissionManager
    }

    func injectText(_ text: String) throws {
        if permissionManager.isTrusted() == false {
            throw KeyboardInjectorError.accessibilityPermissionMissing
        }

        for character in text {
            try injectUnicodeCharacter(String(character))
        }
    }

    func injectKey(key: String, modifiers: [RemoteModifier], action: KeyAction) throws {
        if permissionManager.isTrusted() == false {
            throw KeyboardInjectorError.accessibilityPermissionMissing
        }
        let normalizedKey = mapper.normalizedKey(for: key)
        guard let keyCode = mapper.keyCode(for: normalizedKey) else {
            throw KeyboardInjectorError.keyNotMapped("\(key) (normalized: \(normalizedKey))")
        }

        let flags = mapper.eventFlags(for: modifiers)
        switch action {
        case .down:
            try postKeyEvent(keyCode: keyCode, keyDown: true, flags: flags)
        case .up:
            try postKeyEvent(keyCode: keyCode, keyDown: false, flags: flags)
        case .tap:
            try postKeyEvent(keyCode: keyCode, keyDown: true, flags: flags)
            try postKeyEvent(keyCode: keyCode, keyDown: false, flags: flags)
        }
    }

    func injectMouseMove(deltaX: Double, deltaY: Double) throws {
        if permissionManager.isTrusted() == false {
            throw KeyboardInjectorError.accessibilityPermissionMissing
        }

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let currentEvent = CGEvent(source: eventSource) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        let current = currentEvent.location
        let nextPoint = CGPoint(x: current.x + deltaX, y: current.y - deltaY)
        guard let moveEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: nextPoint,
            mouseButton: .left
        ) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        moveEvent.post(tap: .cghidEventTap)
    }

    func injectMouseClick(button: MouseButton, action: KeyAction) throws {
        if permissionManager.isTrusted() == false {
            throw KeyboardInjectorError.accessibilityPermissionMissing
        }

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let currentEvent = CGEvent(source: eventSource) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        let cursor = currentEvent.location
        let mappedButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            mappedButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            mappedButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        case .center:
            mappedButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
        }

        switch action {
        case .down:
            try postMouseEvent(source: eventSource, type: downType, point: cursor, button: mappedButton)
        case .up:
            try postMouseEvent(source: eventSource, type: upType, point: cursor, button: mappedButton)
        case .tap:
            try postMouseEvent(source: eventSource, type: downType, point: cursor, button: mappedButton)
            try postMouseEvent(source: eventSource, type: upType, point: cursor, button: mappedButton)
        }
    }

    func injectMouseScroll(scrollX: Double, scrollY: Double) throws {
        if permissionManager.isTrusted() == false {
            throw KeyboardInjectorError.accessibilityPermissionMissing
        }

        let wheel1 = normalizedScrollDelta(scrollY)
        let wheel2 = normalizedScrollDelta(scrollX)
        guard wheel1 != 0 || wheel2 != 0 else { return }

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        event.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postMouseEvent(source: CGEventSource, type: CGEventType, point: CGPoint, button: CGMouseButton) throws {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        event.post(tap: .cghidEventTap)
    }

    private func normalizedScrollDelta(_ value: Double) -> Int32 {
        let rounded = Int32(value.rounded())
        if rounded != 0 {
            return rounded
        }
        if abs(value) < 0.001 {
            return 0
        }
        return value > 0 ? 1 : -1
    }

    private func injectUnicodeCharacter(_ character: String) throws {
        let scalars = Array(character.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        keyDown.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
        keyUp.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
