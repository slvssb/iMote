import Foundation

public enum RemoteMessageType: String, Codable, Sendable {
    case pair
    case pairAck
    case text
    case key
    case mouseMove
    case mouseClick
    case mouseScroll
    case cursorPosition
    case streamConfig
    case telemetry
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

public enum PointerProfile: String, Codable, CaseIterable, Sendable {
    case linear
    case edgeAssist
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
    public var pointerProfile: PointerProfile?
    public var serverFPS: Double?
    public var captureWidth: Double?
    public var captureHeight: Double?
    public var adaptiveBitrateScale: Double?
    public var skipRatio: Double?
    public var frameBase64: String?

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
        pointerProfile: PointerProfile? = nil,
        serverFPS: Double? = nil,
        captureWidth: Double? = nil,
        captureHeight: Double? = nil,
        adaptiveBitrateScale: Double? = nil,
        skipRatio: Double? = nil,
        frameBase64: String? = nil
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
        self.pointerProfile = pointerProfile
        self.serverFPS = serverFPS
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.adaptiveBitrateScale = adaptiveBitrateScale
        self.skipRatio = skipRatio
        self.frameBase64 = frameBase64
    }

    public static func pair(code: String, deviceName: String, deviceID: String?) -> RemoteMessage {
        RemoteMessage(type: .pair, code: code, deviceName: deviceName, deviceID: deviceID)
    }

    public static func pairAck(success: Bool, token: String?, reason: String?) -> RemoteMessage {
        RemoteMessage(type: .pairAck, token: token, success: success, reason: reason)
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

    public static func mouseMove(deltaX: Double, deltaY: Double, token: String?) -> RemoteMessage {
        RemoteMessage(type: .mouseMove, token: token, deltaX: deltaX, deltaY: deltaY)
    }

    public static func mouseClick(button: MouseButton, action: KeyAction = .tap, token: String?) -> RemoteMessage {
        RemoteMessage(type: .mouseClick, action: action, token: token, button: button)
    }

    public static func mouseScroll(scrollX: Double, scrollY: Double, token: String?) -> RemoteMessage {
        RemoteMessage(type: .mouseScroll, token: token, scrollX: scrollX, scrollY: scrollY)
    }

    public static func cursorPosition(x: Double, y: Double) -> RemoteMessage {
        RemoteMessage(type: .cursorPosition, cursorX: x, cursorY: y)
    }

    public static func streamConfig(qualityMode: PreviewQualityMode, pointerProfile: PointerProfile? = nil, token: String?) -> RemoteMessage {
        RemoteMessage(type: .streamConfig, token: token, qualityMode: qualityMode, pointerProfile: pointerProfile)
    }

    public static func telemetry(
        serverFPS: Double,
        captureWidth: Double,
        captureHeight: Double,
        adaptiveBitrateScale: Double,
        skipRatio: Double
    ) -> RemoteMessage {
        RemoteMessage(
            type: .telemetry,
            serverFPS: serverFPS,
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            adaptiveBitrateScale: adaptiveBitrateScale,
            skipRatio: skipRatio
        )
    }

    public static func screenFrame(frameBase64: String) -> RemoteMessage {
        RemoteMessage(type: .screenFrame, frameBase64: frameBase64)
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
