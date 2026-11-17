import ApplicationServices
import AppKit
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
    private var cachedDisplayBounds: CGRect = .zero
    private var cachedDisplayBoundsTimestamp: CFAbsoluteTime = 0
    private var lastMouseTapTime: CFAbsoluteTime = 0
    private var lastMouseTapLocation: CGPoint = .zero
    private var lastMouseTapButton: MouseButton?
    private var lastMouseTapClickCount: Int64 = 0
    private var pressedMouseButtons: [MouseButton: UUID] = [:]
    private var controlArrowSource: CGEventSource?

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
        guard let resolved = mapper.resolve(key: key, modifiers: modifiers) else {
            if modifiers.isEmpty {
                try injectUnicodeCharacter(key)
                return
            }
            throw KeyboardInjectorError.keyNotMapped(key)
        }

        let keyCode = resolved.keyCode
        let flags = resolved.flags
        switch action {
        case .down:
            try postKeyEvent(keyCode: keyCode, keyDown: true, flags: flags)
        case .up:
            try postKeyEvent(keyCode: keyCode, keyDown: false, flags: flags)
        case .tap:
            if shouldUseControlArrowShortcutPath(keyCode: keyCode, modifiers: modifiers) {
                try postControlArrowViaHID(keyCode: keyCode)
                return
            }
            if modifiers.isEmpty {
                try postKeyEvent(keyCode: keyCode, keyDown: true, flags: flags)
                try postKeyEvent(keyCode: keyCode, keyDown: false, flags: flags)
            } else {
                try postModifiedTap(keyCode: keyCode, modifiers: modifiers, flags: flags)
            }
        }
    }

    func injectMouseMove(deltaX: Double, deltaY: Double, modifiers: [RemoteModifier] = []) throws {
        if permissionManager.isTrusted() == false {
            throw KeyboardInjectorError.accessibilityPermissionMissing
        }

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let currentEvent = CGEvent(source: eventSource) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        let current = currentEvent.location
        let adjustedDelta = adjustedEdgeAwareDelta(from: current, deltaX: deltaX, deltaY: deltaY)
        let rawNextPoint = CGPoint(x: current.x + adjustedDelta.x, y: current.y - adjustedDelta.y)
        let nextPoint = clampedPointToActiveDisplays(rawNextPoint)
        let moveEventType = mouseMoveEventTypeForPressedButtons()
        let moveButton = mouseButtonForPressedButtons()
        guard let moveEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: moveEventType,
            mouseCursorPosition: nextPoint,
            mouseButton: moveButton
        ) else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        moveEvent.flags = mapper.eventFlags(for: modifiers)

        moveEvent.post(tap: .cghidEventTap)
    }

    func injectMouseClick(button: MouseButton, modifiers: [RemoteModifier] = [], action: KeyAction, clientID: UUID) throws {
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
            pressedMouseButtons[button] = clientID
            try postMouseEvent(
                source: eventSource,
                type: downType,
                point: cursor,
                button: mappedButton,
                clickState: 1,
                flags: mapper.eventFlags(for: modifiers)
            )
        case .up:
            pressedMouseButtons.removeValue(forKey: button)
            try postMouseEvent(
                source: eventSource,
                type: upType,
                point: cursor,
                button: mappedButton,
                clickState: 1,
                flags: mapper.eventFlags(for: modifiers)
            )
        case .tap:
            let clickState = nextClickState(for: button, at: cursor)
            let flags = mapper.eventFlags(for: modifiers)
            try postMouseEvent(
                source: eventSource,
                type: downType,
                point: cursor,
                button: mappedButton,
                clickState: clickState,
                flags: flags
            )
            try postMouseEvent(
                source: eventSource,
                type: upType,
                point: cursor,
                button: mappedButton,
                clickState: clickState,
                flags: flags
            )
        }
    }

    /// Posts a button-up for every button this client left down. A dropped up, or a phone that sleeps mid-drag, would otherwise leave the Mac dragging.
    func releasePressedMouseButtons(for clientID: UUID) {
        let held = pressedMouseButtons.compactMap { button, owner in
            owner == clientID ? button : nil
        }
        guard held.isEmpty == false else { return }
        for button in held {
            pressedMouseButtons.removeValue(forKey: button)
        }
        guard permissionManager.isTrusted(),
              let eventSource = CGEventSource(stateID: .combinedSessionState),
              let currentEvent = CGEvent(source: eventSource) else {
            return
        }
        let point = currentEvent.location
        for button in held {
            guard let mapped = mouseEventTypes(for: button) else { continue }
            try? postMouseEvent(
                source: eventSource,
                type: mapped.up,
                point: point,
                button: mapped.button,
                clickState: 1
            )
        }
    }

    func injectMouseScroll(scrollX: Double, scrollY: Double, modifiers: [RemoteModifier] = []) throws {
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
        event.flags = mapper.eventFlags(for: modifiers)

        event.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        tap: CGEventTapLocation = .cghidEventTap
    ) throws {
        try postKeyEvent(
            keyCode: keyCode,
            keyDown: keyDown,
            flags: flags,
            sourceState: .combinedSessionState,
            tap: tap
        )
    }

    private func postKeyEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        sourceState: CGEventSourceStateID,
        tap: CGEventTapLocation
    ) throws {
        guard
            let source = CGEventSource(stateID: sourceState),
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        event.flags = flags
        event.post(tap: tap)
    }

    private func postModifiedTap(keyCode: CGKeyCode, modifiers: [RemoteModifier], flags: CGEventFlags) throws {
        let modifierKeyCodes = modifiers.compactMap(modifierKeyCode(for:))
        if modifierKeyCodes.isEmpty {
            try postKeyEvent(keyCode: keyCode, keyDown: true, flags: flags)
            try postKeyEvent(keyCode: keyCode, keyDown: false, flags: flags)
            return
        }

        for modifierKeyCode in modifierKeyCodes {
            try postKeyEvent(keyCode: modifierKeyCode, keyDown: true, flags: [])
        }

        try postKeyEvent(keyCode: keyCode, keyDown: true, flags: flags)
        try postKeyEvent(keyCode: keyCode, keyDown: false, flags: flags)

        for modifierKeyCode in modifierKeyCodes.reversed() {
            try postKeyEvent(keyCode: modifierKeyCode, keyDown: false, flags: [])
        }
    }

    private func shouldUseControlArrowShortcutPath(keyCode: CGKeyCode, modifiers: [RemoteModifier]) -> Bool {
        guard modifiers.count == 1, modifiers.first == .control else { return false }
        return (123...126).contains(Int(keyCode))
    }

    private func postControlArrowViaHID(keyCode: CGKeyCode) throws {
        guard let controlKeyCode = modifierKeyCode(for: .control) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        if controlArrowSource == nil {
            let src = CGEventSource(stateID: .privateState)
            src?.localEventsSuppressionInterval = 0
            controlArrowSource = src
        }
        guard let source = controlArrowSource else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        let kbdType = Int64(CGEventSource(stateID: .hidSystemState)?.keyboardType ?? 59)
        let deviceLeftControl = CGEventFlags(rawValue: 0x00000001)
        let controlHeld: CGEventFlags = [.maskControl, .maskNonCoalesced, deviceLeftControl]
        let released: CGEventFlags = [.maskNonCoalesced]
        var controlIsDown = false
        defer {
            if controlIsDown {
                postControlRelease(
                    source: source,
                    controlKeyCode: controlKeyCode,
                    keyboardType: kbdType,
                    flags: released
                )
            }
        }

        guard let clearFlags = CGEvent(keyboardEventSource: source, virtualKey: controlKeyCode, keyDown: false) else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        clearFlags.type = .flagsChanged
        clearFlags.flags = released
        clearFlags.setIntegerValueField(.keyboardEventKeyboardType, value: kbdType)
        clearFlags.post(tap: .cghidEventTap)

        guard let ctrlDown = CGEvent(keyboardEventSource: source, virtualKey: controlKeyCode, keyDown: true) else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        ctrlDown.type = .flagsChanged
        ctrlDown.flags = controlHeld
        ctrlDown.setIntegerValueField(.keyboardEventKeyboardType, value: kbdType)
        ctrlDown.post(tap: .cghidEventTap)
        controlIsDown = true

        guard let arrowDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        arrowDown.flags = controlHeld
        arrowDown.setIntegerValueField(.keyboardEventKeyboardType, value: kbdType)
        arrowDown.post(tap: .cghidEventTap)

        guard let arrowUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw KeyboardInjectorError.eventBuildFailed
        }
        arrowUp.flags = controlHeld
        arrowUp.setIntegerValueField(.keyboardEventKeyboardType, value: kbdType)
        arrowUp.post(tap: .cghidEventTap)

        postControlRelease(
            source: source,
            controlKeyCode: controlKeyCode,
            keyboardType: kbdType,
            flags: released
        )
        controlIsDown = false
    }

    private func postControlRelease(
        source: CGEventSource,
        controlKeyCode: CGKeyCode,
        keyboardType: Int64,
        flags: CGEventFlags
    ) {
        guard let ctrlUp = CGEvent(keyboardEventSource: source, virtualKey: controlKeyCode, keyDown: false) else {
            return
        }
        ctrlUp.type = .flagsChanged
        ctrlUp.flags = flags
        ctrlUp.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
        ctrlUp.post(tap: .cghidEventTap)
    }

    private func modifierKeyCode(for modifier: RemoteModifier) -> CGKeyCode? {
        switch modifier {
        case .command:
            return 55
        case .option:
            return 58
        case .shift:
            return 56
        case .control:
            return 59
        }
    }

    private func postMouseEvent(
        source: CGEventSource,
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        clickState: Int64,
        flags: CGEventFlags = []
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            throw KeyboardInjectorError.eventBuildFailed
        }

        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func nextClickState(for button: MouseButton, at point: CGPoint) -> Int64 {
        let now = CFAbsoluteTimeGetCurrent()
        let maxInterval: CFAbsoluteTime = 0.40
        let maxDistance: CGFloat = 6

        let isSameButton = (lastMouseTapButton == button)
        let isWithinInterval = (now - lastMouseTapTime) <= maxInterval
        let isWithinDistance = hypot(point.x - lastMouseTapLocation.x, point.y - lastMouseTapLocation.y) <= maxDistance

        if isSameButton, isWithinInterval, isWithinDistance {
            lastMouseTapClickCount = min(lastMouseTapClickCount + 1, 3)
        } else {
            lastMouseTapClickCount = 1
        }

        lastMouseTapButton = button
        lastMouseTapLocation = point
        lastMouseTapTime = now
        return lastMouseTapClickCount
    }

    private func mouseMoveEventTypeForPressedButtons() -> CGEventType {
        if pressedMouseButtons[.left] != nil {
            return .leftMouseDragged
        }
        if pressedMouseButtons[.right] != nil {
            return .rightMouseDragged
        }
        if pressedMouseButtons[.center] != nil {
            return .otherMouseDragged
        }
        return .mouseMoved
    }

    private func mouseButtonForPressedButtons() -> CGMouseButton {
        if pressedMouseButtons[.left] != nil {
            return .left
        }
        if pressedMouseButtons[.right] != nil {
            return .right
        }
        if pressedMouseButtons[.center] != nil {
            return .center
        }
        return .left
    }

    private func mouseEventTypes(for button: MouseButton) -> (button: CGMouseButton, down: CGEventType, up: CGEventType)? {
        switch button {
        case .left:
            return (.left, .leftMouseDown, .leftMouseUp)
        case .right:
            return (.right, .rightMouseDown, .rightMouseUp)
        case .center:
            return (.center, .otherMouseDown, .otherMouseUp)
        }
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
        // A virtual key of 0 is the ANSI A key. Some apps insert that character as well as the Unicode string.
        keyDown.setIntegerValueField(.keyboardEventKeycode, value: 0xFF)
        keyUp.setIntegerValueField(.keyboardEventKeycode, value: 0xFF)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func adjustedEdgeAwareDelta(from current: CGPoint, deltaX: Double, deltaY: Double) -> CGPoint {
        let bounds = activeDisplayBounds()
        guard bounds.isNull == false, bounds.isEmpty == false else {
            return CGPoint(x: deltaX, y: deltaY)
        }

        let edgeZone: CGFloat = 110
        let leftDistance = max(0, current.x - bounds.minX)
        let rightDistance = max(0, bounds.maxX - current.x)
        let bottomDistance = max(0, current.y - bounds.minY)
        let topDistance = max(0, bounds.maxY - current.y)

        let xEdgeFactor = edgeFactor(min(leftDistance, rightDistance), zone: edgeZone)
        let yEdgeFactor = edgeFactor(min(bottomDistance, topDistance), zone: edgeZone)

        let isNearLeft = leftDistance < rightDistance
        let isNearBottom = bottomDistance < topDistance

        var adjustedX = deltaX
        var adjustedY = deltaY

        if xEdgeFactor > 0 {
            let movingOutwardX = (isNearLeft && deltaX < 0) || (isNearLeft == false && deltaX > 0)
            if movingOutwardX {
                adjustedX *= (1 - (0.30 * xEdgeFactor))
            }
            adjustedY *= (1 + (0.22 * xEdgeFactor))
        }

        if yEdgeFactor > 0 {
            let movingOutwardY = (isNearBottom && deltaY > 0) || (isNearBottom == false && deltaY < 0)
            if movingOutwardY {
                adjustedY *= (1 - (0.30 * yEdgeFactor))
            }
            adjustedX *= (1 + (0.22 * yEdgeFactor))
        }

        return CGPoint(x: adjustedX, y: adjustedY)
    }

    private func edgeFactor(_ distance: CGFloat, zone: CGFloat) -> Double {
        guard zone > 0 else { return 0 }
        let normalized = max(0, min(1, 1 - (distance / zone)))
        return Double(normalized)
    }

    private func clampedPointToActiveDisplays(_ point: CGPoint) -> CGPoint {
        let bounds = activeDisplayBounds()
        guard bounds.isNull == false, bounds.isEmpty == false else { return point }

        let minX = bounds.minX
        let maxX = bounds.maxX - 1
        let minY = bounds.minY
        let maxY = bounds.maxY - 1

        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private func activeDisplayBounds() -> CGRect {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedDisplayBoundsTimestamp < 1.0, cachedDisplayBounds.isEmpty == false {
            return cachedDisplayBounds
        }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return cachedDisplayBounds
        }

        var displayIDs = Array<CGDirectDisplayID>(repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return cachedDisplayBounds
        }

        var unionBounds = CGRect.null
        for displayID in displayIDs {
            unionBounds = unionBounds.union(CGDisplayBounds(displayID))
        }

        cachedDisplayBounds = unionBounds
        cachedDisplayBoundsTimestamp = now
        return unionBounds
    }
}
