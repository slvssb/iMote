import Foundation
import CryptoKit
import UIKit

@MainActor
final class IOSWebSocketClient: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case securing
        case paired
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var pairedToken: String?

    var onRemoteError: ((String) -> Void)?
    var onScreenFrame: ((Data) -> Void)?
    var onCursorPosition: ((Double, Double) -> Void)?
    var onH264Config: ((Data) -> Void)?
    var onH264Frame: ((Data) -> Void)?
    var onAACConfig: ((Data) -> Void)?
    var onAACFrame: ((Data) -> Void)?
    var onThermalOverrideChanged: ((Bool) -> Void)?
    var onHostCaptureStatusChanged: ((RemoteMessage) -> Void)?
    var onPermissionStatus: ((Bool, Bool) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var lastHost: String?
    private var lastPort: Int?
    private var lastPairCode: String?
    private var reconnectAttempts = 0
    private var shouldReconnect = false
    private let deviceIdentifier = UIDevice.current.identifierForVendor?.uuidString
    private var activeConnectionGeneration: UInt64 = 0
    private var audioDebugReceivedConfigCount = 0
    private var audioDebugReceivedFrameCount = 0
    private var controlChannelKey: SymmetricKey?
    private var mediaChannelKey: SymmetricKey?
    private var localSigningPrivateKey = IOSWebSocketClient.loadOrCreateSigningPrivateKey()
    private var handshakeEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var pendingHostDeviceID: String?
    private var hasCompletedSecureHandshake = false
    private let fallbackDeviceID = UUID().uuidString

    private enum BinaryPacketMarker {
        static let encryptedMedia: UInt8 = 0x7E
        static let h264Config: UInt8 = 0x10
        static let h264Frame: UInt8 = 0x11
        static let aacConfig: UInt8 = 0x20
        static let aacFrame: UInt8 = 0x21
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(host: String, port: Int, pairingCode: String) {
        disconnect(userInitiated: true)
        state = .connecting
        shouldReconnect = true
        reconnectAttempts = 0
        activeConnectionGeneration &+= 1
        let generation = activeConnectionGeneration
        lastHost = host
        lastPort = port
        lastPairCode = pairingCode

        guard let url = URL(string: "ws://\(host):\(port)") else {
            state = .failed("Invalid host/port")
            return
        }

        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        listen(on: wsTask, generation: generation)
        sendPairing(code: pairingCode)
    }

    func disconnect(userInitiated: Bool = true) {
        if userInitiated {
            shouldReconnect = false
            activeConnectionGeneration &+= 1
        }
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        pairedToken = nil
        controlChannelKey = nil
        mediaChannelKey = nil
        handshakeEphemeralPrivateKey = nil
        pendingHostDeviceID = nil
        hasCompletedSecureHandshake = false
        if userInitiated {
            state = .disconnected
        }
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        sendMessage(RemoteMessage.text(text, token: pairedToken))
    }

    func sendKey(_ key: String, modifiers: [RemoteModifier], action: KeyAction = .tap) {
        sendMessage(RemoteMessage.key(key, modifiers: modifiers, action: action, token: pairedToken))
    }

    func sendMouseMove(deltaX: Double, deltaY: Double, modifiers: [RemoteModifier] = []) {
        sendMessage(RemoteMessage.mouseMove(deltaX: deltaX, deltaY: deltaY, modifiers: modifiers, token: pairedToken))
    }

    func sendMouseClick(button: MouseButton, modifiers: [RemoteModifier] = [], action: KeyAction = .tap) {
        sendMessage(RemoteMessage.mouseClick(button: button, modifiers: modifiers, action: action, token: pairedToken))
    }

    func sendMouseScroll(scrollX: Double, scrollY: Double, modifiers: [RemoteModifier] = []) {
        sendMessage(RemoteMessage.mouseScroll(scrollX: scrollX, scrollY: scrollY, modifiers: modifiers, token: pairedToken))
    }

    func sendStreamConfig(qualityMode: PreviewQualityMode, previewZoomLevel: Double?) {
        sendMessage(RemoteMessage.streamConfig(qualityMode: qualityMode, previewZoomLevel: previewZoomLevel, token: pairedToken))
    }

    func sendStreamResync() {
        sendMessage(RemoteMessage.streamResync(token: pairedToken))
    }

    func sendForgetCurrentDeviceTrust() {
        sendMessage(RemoteMessage.trustControl(action: .forgetCurrentDevice, token: pairedToken, deviceID: deviceIdentifier))
    }

    func sendAudioConfig(source: AudioCaptureSource) {
        sendMessage(RemoteMessage.audioConfig(source: source, token: pairedToken))
    }

    func requestPermissionStatus() {
        sendMessage(RemoteMessage.permissionStatusRequest(token: pairedToken))
    }

    func sendPermissionAction(_ action: HostPermissionAction) {
        sendMessage(RemoteMessage.permissionAction(action, token: pairedToken))
    }

    func sendDisplayControl(displayID: UInt32?, virtualDisplayWhenHeadless: Bool?) {
        sendMessage(RemoteMessage.displayControl(
            displayID: displayID,
            virtualDisplayWhenHeadless: virtualDisplayWhenHeadless,
            token: pairedToken
        ))
    }

    private func sendPairing(code: String) {
        let deviceName = UIDevice.current.name
        sendMessage(.pair(code: code, deviceName: deviceName, deviceID: deviceIdentifier))
    }

    private func sendMessage(_ message: RemoteMessage) {
        guard let task else { return }
        do {
            let outboundMessage: RemoteMessage
            if shouldEncryptOutgoingControl(message: message) {
                guard let key = controlChannelKey else {
                    // Avoid leaking control intent before authenticated secure handshake is complete.
                    return
                }
                let plaintext = try RemoteProtocolCodec.encode(message)
                let sealedBox = try ChaChaPoly.seal(plaintext, using: key)
                outboundMessage = .secureControl(
                    payloadBase64: sealedBox.combined.base64EncodedString(),
                    token: pairedToken
                )
            } else {
                outboundMessage = message
            }

            let payload = try RemoteProtocolCodec.encode(outboundMessage)
            task.send(.data(payload)) { [weak self] error in
                guard let self else { return }
                if let error {
                    Task { @MainActor in
                        self.handleError(error.localizedDescription)
                    }
                }
            }
        } catch {
            handleError(error.localizedDescription)
        }
    }

    private func listen(on task: URLSessionWebSocketTask, generation: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard generation == self.activeConnectionGeneration, task == self.task else {
                    return
                }
                switch result {
                case let .success(message):
                    self.handleIncoming(message)
                    self.listen(on: task, generation: generation)
                case let .failure(error):
                    self.handleDisconnect(error: error)
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .data(payload):
            data = payload
        case let .string(text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        if handleBinaryVideoPacket(data) {
            return
        }

        if let decoded = try? RemoteProtocolCodec.decode(data) {
            switch decoded.type {
            case .pairAck:
                if decoded.success == true, let token = decoded.token {
                    pairedToken = token
                    pendingHostDeviceID = decoded.deviceID
                    reconnectAttempts = 0
                    state = .securing
                    startSecureHandshake(using: token)
                } else {
                    let reason = decoded.reason ?? "Pairing failed"
                    // Stop reconnect loops when pairing is rejected.
                    shouldReconnect = false
                    state = .failed(reason)
                    task?.cancel(with: .normalClosure, reason: nil)
                }
            case .error:
                let reason = decoded.reason ?? "Unknown error"
                onRemoteError?(reason)
                state = .failed(reason)
            case .e2eHelloAck:
                handleSecureHelloAck(decoded)
            case .screenFrame:
                if let frameBase64 = decoded.frameBase64,
                   let frameData = Data(base64Encoded: frameBase64) {
                    onScreenFrame?(frameData)
                }
            case .cursorPosition:
                if let x = decoded.cursorX, let y = decoded.cursorY {
                    onCursorPosition?(x, y)
                }
            case .pong:
                break
            case .streamStatus:
                onThermalOverrideChanged?(decoded.thermalOverrideActive ?? false)
                onHostCaptureStatusChanged?(decoded)
            case .permissionStatus:
                onPermissionStatus?(decoded.accessibilityGranted ?? false, decoded.screenRecordingGranted ?? false)
            default:
                break
            }
            return
        }

        if isLikelyJPEG(data) {
            onScreenFrame?(data)
        }
    }

    private func handleBinaryVideoPacket(_ data: Data) -> Bool {
        guard let marker = data.first, data.count > 1 else { return false }
        if marker == BinaryPacketMarker.encryptedMedia {
            guard let mediaChannelKey else { return false }
            let combined = data.dropFirst()
            do {
                let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
                let plaintext = try ChaChaPoly.open(sealedBox, using: mediaChannelKey)
                return handleBinaryVideoPacket(plaintext)
            } catch {
                handleError("Unable to decrypt media payload")
                return true
            }
        }

        let payload = data.dropFirst()

        switch marker {
        case BinaryPacketMarker.h264Config:
            onH264Config?(Data(payload))
            return true
        case BinaryPacketMarker.h264Frame:
            onH264Frame?(Data(payload))
            return true
        case BinaryPacketMarker.aacConfig:
            audioDebugReceivedConfigCount += 1
            print("[AudioDebug][ios-client] received config #\(audioDebugReceivedConfigCount)")
            onAACConfig?(Data(payload))
            return true
        case BinaryPacketMarker.aacFrame:
            audioDebugReceivedFrameCount += 1
            if audioDebugReceivedFrameCount % 120 == 0 {
                print("[AudioDebug][ios-client] received frames=\(audioDebugReceivedFrameCount)")
            }
            onAACFrame?(Data(payload))
            return true
        default:
            return false
        }
    }

    private func isLikelyJPEG(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        return bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sendMessage(RemoteMessage(type: .ping, token: self.pairedToken))
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func handleError(_ reason: String) {
        state = .failed(reason)
        onRemoteError?(reason)
    }

    private func handleDisconnect(error: Error?) {
        stopPing()
        pairedToken = nil
        controlChannelKey = nil
        mediaChannelKey = nil
        handshakeEphemeralPrivateKey = nil
        pendingHostDeviceID = nil
        hasCompletedSecureHandshake = false

        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .disconnected
        }

        guard shouldReconnect,
              reconnectAttempts < 10,
              let host = lastHost,
              let port = lastPort,
              let pairCode = lastPairCode else {
            return
        }

        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts), 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect(host: host, port: port, pairingCode: pairCode)
        }
    }

    private func shouldEncryptOutgoingControl(message: RemoteMessage) -> Bool {
        guard hasCompletedSecureHandshake else { return false }
        switch message.type {
        case .text,
             .key,
             .mouseMove,
             .mouseClick,
             .mouseScroll,
             .streamConfig,
             .streamResync,
             .audioConfig,
             .permissionStatusRequest,
             .permissionAction,
             .trustControl,
             .displayControl:
            return true
        default:
            return false
        }
    }

    private static func makeControlChannelKey(from token: String) -> SymmetricKey {
        SymmetricKey(data: Data(token.utf8))
    }

    private func startSecureHandshake(using token: String) {
        do {
            let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            handshakeEphemeralPrivateKey = ephemeralPrivateKey
            let deviceID = deviceIdentifier ?? fallbackDeviceID
            let ephemeralPublicData = ephemeralPrivateKey.publicKey.rawRepresentation
            let signingPublicData = localSigningPrivateKey.publicKey.rawRepresentation
            let signaturePayload = Self.signaturePayload(token: token, deviceID: deviceID, ephemeralPublicKey: ephemeralPublicData)
            let signature = try localSigningPrivateKey.signature(for: signaturePayload)

            sendMessage(.e2eHello(
                deviceID: deviceID,
                signingPublicKey: signingPublicData.base64EncodedString(),
                ephemeralPublicKey: ephemeralPublicData.base64EncodedString(),
                signature: signature.base64EncodedString(),
                token: token
            ))
        } catch {
            handleError("Failed to start secure handshake")
        }
    }

    private func handleSecureHelloAck(_ message: RemoteMessage) {
        guard let token = pairedToken,
              let hostDeviceID = message.deviceID,
              let hostSigningPublicKeyBase64 = message.signingPublicKey,
              let hostEphemeralPublicKeyBase64 = message.ephemeralPublicKey,
              let signatureBase64 = message.signature,
              let hostSigningPublicKeyData = Data(base64Encoded: hostSigningPublicKeyBase64),
              let hostEphemeralPublicKeyData = Data(base64Encoded: hostEphemeralPublicKeyBase64),
              let signatureData = Data(base64Encoded: signatureBase64),
              let ephemeralPrivateKey = handshakeEphemeralPrivateKey else {
            handleError("Malformed secure handshake response")
            return
        }

        guard verifyOrPinHostSigningKey(hostDeviceID: hostDeviceID, signingPublicKeyBase64: hostSigningPublicKeyBase64) else {
            handleError("Host identity key mismatch. Re-pair required.")
            return
        }

        do {
            let hostSigningPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: hostSigningPublicKeyData)
            let signaturePayload = Self.signaturePayload(token: token, deviceID: hostDeviceID, ephemeralPublicKey: hostEphemeralPublicKeyData)
            guard hostSigningPublicKey.isValidSignature(signatureData, for: signaturePayload) else {
                handleError("Invalid secure handshake signature")
                return
            }

            let hostEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEphemeralPublicKeyData)
            let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: hostEphemeralPublicKey)
            let salt = Data(token.utf8)
            controlChannelKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("iMote.e2e.control.v1".utf8),
                outputByteCount: 32
            )
            mediaChannelKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("iMote.e2e.media.v1".utf8),
                outputByteCount: 32
            )
            hasCompletedSecureHandshake = true
            state = .paired
            startPing()
        } catch {
            handleError("Failed to finalize secure handshake")
        }
    }

    private static func signaturePayload(token: String, deviceID: String, ephemeralPublicKey: Data) -> Data {
        var payload = Data()
        payload.append(contentsOf: Data("iMote.e2e.handshake.v1|".utf8))
        payload.append(contentsOf: Data(token.utf8))
        payload.append(contentsOf: Data("|".utf8))
        payload.append(contentsOf: Data(deviceID.utf8))
        payload.append(contentsOf: Data("|".utf8))
        payload.append(ephemeralPublicKey)
        return payload
    }

    private static func loadOrCreateSigningPrivateKey() -> Curve25519.Signing.PrivateKey {
        let keyName = "remoteKeyboard.ios.signingPrivateKey"
        if let stored = UserDefaults.standard.string(forKey: keyName),
           let storedData = Data(base64Encoded: stored),
           let existing = try? Curve25519.Signing.PrivateKey(rawRepresentation: storedData) {
            return existing
        }

        let created = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(created.rawRepresentation.base64EncodedString(), forKey: keyName)
        return created
    }

    private func verifyOrPinHostSigningKey(hostDeviceID: String, signingPublicKeyBase64: String) -> Bool {
        let keyName = "remoteKeyboard.ios.trustedHostSigningKeys"
        var map = UserDefaults.standard.dictionary(forKey: keyName) as? [String: String] ?? [:]
        if let existing = map[hostDeviceID] {
            return existing == signingPublicKeyBase64
        }
        map[hostDeviceID] = signingPublicKeyBase64
        UserDefaults.standard.set(map, forKey: keyName)
        return true
    }
}

extension IOSWebSocketClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            if case .connecting = state {
                state = .connected
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            guard webSocketTask == self.task else { return }
            self.handleDisconnect(error: nil)
        }
    }
}
