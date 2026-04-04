import Foundation

public enum RemoteMessageType: String, Codable, Sendable {
    case pair
    case pairAck
    case e2eHello
    case e2eHelloAck
    case secureControl
    case text
    case key
    case mouseMove
    case mouseClick
    case mouseScroll
    case cursorPosition
    case streamConfig
    case streamResync
    case trustControl
    case streamStatus
    case audioConfig
    case permissionStatusRequest
    case permissionStatus
    case permissionAction
    case screenFrame
    case ping
    case pong
    case error
}

public enum KeyAction: String, Codable, Sendable {
    case down
    case up
    case tap
}

public enum RemoteModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case shift
    case control
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case center
}

public enum PreviewQualityMode: String, Codable, CaseIterable, Sendable {
    case balanced
    case ultra
}

public enum AudioCaptureSource: String, Codable, CaseIterable, Sendable {
    case off
    case systemOutput
    case microphone
    case systemAndMicrophone
}

public enum TrustControlAction: String, Codable, Sendable {
    case forgetCurrentDevice
}

public enum HostPermissionAction: String, Codable, Sendable {
    case requestAccessibilityPrompt
    case requestScreenRecordingPrompt
    case openAccessibilitySettings
    case openScreenRecordingSettings
}

public struct RemoteMessage: Codable, Sendable {
    public var type: RemoteMessageType
    public var value: String?
    public var key: String?
    public var modifiers: [RemoteModifier]?
    public var action: KeyAction?
    public var code: String?
    public var token: String?
    public var success: Bool?
    public var reason: String?
    public var deviceName: String?
    public var deviceID: String?
    public var deltaX: Double?
    public var deltaY: Double?
    public var scrollX: Double?
    public var scrollY: Double?
    public var cursorX: Double?
    public var cursorY: Double?
    public var button: MouseButton?
    public var qualityMode: PreviewQualityMode?
    public var previewZoomLevel: Double?
    public var trustAction: TrustControlAction?
    public var thermalOverrideActive: Bool?
    public var frameBase64: String?
    public var audioSource: AudioCaptureSource?
    public var permissionAction: HostPermissionAction?
    public var accessibilityGranted: Bool?
    public var screenRecordingGranted: Bool?
    public var securePayload: String?
    public var signingPublicKey: String?
    public var ephemeralPublicKey: String?
    public var signature: String?

    public init(
        type: RemoteMessageType,
        value: String? = nil,
        key: String? = nil,
        modifiers: [RemoteModifier]? = nil,
        action: KeyAction? = nil,
        code: String? = nil,
        token: String? = nil,
        success: Bool? = nil,
        reason: String? = nil,
        deviceName: String? = nil,
        deviceID: String? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        cursorX: Double? = nil,
        cursorY: Double? = nil,
        button: MouseButton? = nil,
        qualityMode: PreviewQualityMode? = nil,
        previewZoomLevel: Double? = nil,
        trustAction: TrustControlAction? = nil,
        thermalOverrideActive: Bool? = nil,
        frameBase64: String? = nil,
        audioSource: AudioCaptureSource? = nil,
        permissionAction: HostPermissionAction? = nil,
        accessibilityGranted: Bool? = nil,
        screenRecordingGranted: Bool? = nil,
        securePayload: String? = nil,
        signingPublicKey: String? = nil,
        ephemeralPublicKey: String? = nil,
        signature: String? = nil
    ) {
        self.type = type
        self.value = value
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.code = code
        self.token = token
        self.success = success
        self.reason = reason
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.button = button
        self.qualityMode = qualityMode
        self.previewZoomLevel = previewZoomLevel
        self.trustAction = trustAction
        self.thermalOverrideActive = thermalOverrideActive
        self.frameBase64 = frameBase64
        self.audioSource = audioSource
        self.permissionAction = permissionAction
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.securePayload = securePayload
        self.signingPublicKey = signingPublicKey
        self.ephemeralPublicKey = ephemeralPublicKey
        self.signature = signature
    }

    public static func pair(code: String, deviceName: String, deviceID: String?) -> RemoteMessage {
        RemoteMessage(type: .pair, code: code, deviceName: deviceName, deviceID: deviceID)
    }

    public static func pairAck(success: Bool, token: String?, reason: String?) -> RemoteMessage {
        RemoteMessage(type: .pairAck, token: token, success: success, reason: reason)
    }

    public static func secureControl(payloadBase64: String, token: String?) -> RemoteMessage {
        RemoteMessage(type: .secureControl, token: token, securePayload: payloadBase64)
    }

    public static func e2eHello(
        deviceID: String,
        signingPublicKey: String,
        ephemeralPublicKey: String,
        signature: String,
        token: String?
    ) -> RemoteMessage {
        RemoteMessage(
            type: .e2eHello,
            token: token,
            deviceID: deviceID,
            signingPublicKey: signingPublicKey,
            ephemeralPublicKey: ephemeralPublicKey,
            signature: signature
        )
    }

    public static func e2eHelloAck(
        deviceID: String,
        signingPublicKey: String,
        ephemeralPublicKey: String,
        signature: String,
        token: String?
    ) -> RemoteMessage {
        RemoteMessage(
            type: .e2eHelloAck,
            token: token,
            deviceID: deviceID,
            signingPublicKey: signingPublicKey,
            ephemeralPublicKey: ephemeralPublicKey,
            signature: signature
        )
    }

    public static func text(_ text: String, token: String?) -> RemoteMessage {
        RemoteMessage(type: .text, value: text, token: token)
    }

    public static func key(
        _ key: String,
        modifiers: [RemoteModifier] = [],
        action: KeyAction = .tap,
        token: String?
    ) -> RemoteMessage {
        RemoteMessage(type: .key, key: key, modifiers: modifiers, action: action, token: token)
    }

    public static func mouseMove(
        deltaX: Double,
        deltaY: Double,
        modifiers: [RemoteModifier] = [],
        token: String?
    ) -> RemoteMessage {
        RemoteMessage(type: .mouseMove, modifiers: modifiers, token: token, deltaX: deltaX, deltaY: deltaY)
    }

    public static func mouseClick(
        button: MouseButton,
        modifiers: [RemoteModifier] = [],
        action: KeyAction = .tap,
        token: String?
    ) -> RemoteMessage {
        RemoteMessage(type: .mouseClick, modifiers: modifiers, action: action, token: token, button: button)
    }

    public static func mouseScroll(
        scrollX: Double,
        scrollY: Double,
        modifiers: [RemoteModifier] = [],
        token: String?
    ) -> RemoteMessage {
        RemoteMessage(type: .mouseScroll, modifiers: modifiers, token: token, scrollX: scrollX, scrollY: scrollY)
    }

    public static func cursorPosition(x: Double, y: Double) -> RemoteMessage {
        RemoteMessage(type: .cursorPosition, cursorX: x, cursorY: y)
    }

    public static func streamConfig(qualityMode: PreviewQualityMode, previewZoomLevel: Double?, token: String?) -> RemoteMessage {
        RemoteMessage(type: .streamConfig, token: token, qualityMode: qualityMode, previewZoomLevel: previewZoomLevel)
    }

    public static func streamResync(token: String?) -> RemoteMessage {
        RemoteMessage(type: .streamResync, token: token)
    }

    public static func trustControl(action: TrustControlAction, token: String?, deviceID: String?) -> RemoteMessage {
        RemoteMessage(type: .trustControl, token: token, deviceID: deviceID, trustAction: action)
    }

    public static func streamStatus(thermalOverrideActive: Bool) -> RemoteMessage {
        RemoteMessage(type: .streamStatus, thermalOverrideActive: thermalOverrideActive)
    }

    public static func audioConfig(source: AudioCaptureSource, token: String?) -> RemoteMessage {
        RemoteMessage(type: .audioConfig, token: token, audioSource: source)
    }

    public static func screenFrame(frameBase64: String) -> RemoteMessage {
        RemoteMessage(type: .screenFrame, frameBase64: frameBase64)
    }

    public static func permissionStatusRequest(token: String?) -> RemoteMessage {
        RemoteMessage(type: .permissionStatusRequest, token: token)
    }

    public static func permissionStatus(accessibilityGranted: Bool, screenRecordingGranted: Bool) -> RemoteMessage {
        RemoteMessage(
            type: .permissionStatus,
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted
        )
    }

    public static func permissionAction(_ action: HostPermissionAction, token: String?) -> RemoteMessage {
        RemoteMessage(type: .permissionAction, token: token, permissionAction: action)
    }

    public static func error(_ reason: String) -> RemoteMessage {
        RemoteMessage(type: .error, reason: reason)
    }

}

public enum RemoteProtocolCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func decode(_ data: Data) throws -> RemoteMessage {
        try decoder.decode(RemoteMessage.self, from: data)
    }

    public static func encode(_ message: RemoteMessage) throws -> Data {
        try encoder.encode(message)
    }
}
