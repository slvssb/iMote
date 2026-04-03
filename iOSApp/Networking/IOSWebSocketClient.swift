import Foundation
import UIKit

@MainActor
final class IOSWebSocketClient: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
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
    var onThermalOverrideChanged: ((Bool) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var lastHost: String?
    private var lastPort: Int?
    private var lastPairCode: String?
    private var reconnectAttempts = 0
    private var shouldReconnect = false
    private let deviceIdentifier = UIDevice.current.identifierForVendor?.uuidString

    private enum BinaryPacketMarker {
        static let h264Config: UInt8 = 0x10
        static let h264Frame: UInt8 = 0x11
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
        listen()
        sendPairing(code: pairingCode)
    }

    func disconnect(userInitiated: Bool = true) {
        if userInitiated {
            shouldReconnect = false
        }
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        pairedToken = nil
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

    func sendMouseMove(deltaX: Double, deltaY: Double) {
        sendMessage(RemoteMessage.mouseMove(deltaX: deltaX, deltaY: deltaY, token: pairedToken))
    }

    func sendMouseClick(button: MouseButton, action: KeyAction = .tap) {
        sendMessage(RemoteMessage.mouseClick(button: button, action: action, token: pairedToken))
    }

    func sendMouseScroll(scrollX: Double, scrollY: Double) {
        sendMessage(RemoteMessage.mouseScroll(scrollX: scrollX, scrollY: scrollY, token: pairedToken))
    }

    func sendStreamConfig(qualityMode: PreviewQualityMode, previewZoomLevel: Double?) {
        sendMessage(RemoteMessage.streamConfig(qualityMode: qualityMode, previewZoomLevel: previewZoomLevel, token: pairedToken))
    }

    func sendForgetCurrentDeviceTrust() {
        sendMessage(RemoteMessage.trustControl(action: .forgetCurrentDevice, token: pairedToken, deviceID: deviceIdentifier))
    }

    private func sendPairing(code: String) {
        let deviceName = UIDevice.current.name
        sendMessage(.pair(code: code, deviceName: deviceName, deviceID: deviceIdentifier))
    }

    private func sendMessage(_ message: RemoteMessage) {
        guard let task else { return }
        do {
            let payload = try RemoteProtocolCodec.encode(message)
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

    private func listen() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case let .success(message):
                    self.handleIncoming(message)
                    self.listen()
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
                    reconnectAttempts = 0
                    state = .paired
                    startPing()
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
        let payload = data.dropFirst()

        switch marker {
        case BinaryPacketMarker.h264Config:
            onH264Config?(Data(payload))
            return true
        case BinaryPacketMarker.h264Frame:
            onH264Frame?(Data(payload))
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
            self.handleDisconnect(error: nil)
        }
    }
}
