import Combine
import Foundation

@MainActor
final class IOSKeyboardViewModel: ObservableObject {
    @Published var services: [DiscoveredService] = []
    @Published var selectedService: DiscoveredService?
    @Published var pairingCode = ""
    @Published var activeModifiers: Set<RemoteModifier> = []
    @Published var lastError: String?
    @Published var connectionLabel = "Disconnected"
    @Published var previewQualityMode: PreviewQualityMode = .ultra
    @Published var isThermalQualityOverrideActive = false

    let screenPreview = ScreenPreviewState()

    var isConnected: Bool {
        switch client.state {
        case .connected, .paired:
            return true
        default:
            return false
        }
    }

    var isDisconnected: Bool {
        if case .disconnected = client.state {
            return true
        }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = client.state {
            return true
        }
        return false
    }

    var isPaired: Bool {
        if case .paired = client.state {
            return true
        }
        return false
    }

    var isTrustedAutoReconnect: Bool {
        hasTrustedSession && pairingCode.isEmpty
    }

    var hasTrustedSessionLocally: Bool {
        hasTrustedSession
    }

    private let browser = BonjourServiceBrowser()
    private let client = IOSWebSocketClient()
    private let h264Decoder = H264FrameDecoder()
    private var cancellables: Set<AnyCancellable> = []
    private var previewZoomLevel: Double = 1.0

    private let trustedSessionKey = "remoteKeyboard.trustedSession"
    private var hasTrustedSession: Bool {
        get { UserDefaults.standard.bool(forKey: trustedSessionKey) }
        set { UserDefaults.standard.set(newValue, forKey: trustedSessionKey) }
    }

    init() {
        browser.$services
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                guard let self else { return }
                self.services = updated
                if self.selectedService == nil {
                    self.selectedService = updated.first
                } else if let selected = self.selectedService {
                    let stillPresent = updated.contains { service in
                        service.host == selected.host && service.port == selected.port
                    }
                    if stillPresent == false {
                        self.selectedService = updated.first
                    }
                }

                if self.hasTrustedSession,
                   self.isDisconnected,
                   self.selectedService != nil {
                    self.connect()
                }
            }
            .store(in: &cancellables)

        client.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .disconnected:
                    self.connectionLabel = "Disconnected"
                    self.isThermalQualityOverrideActive = false
                    self.screenPreview.reset()
                case .connecting:
                    self.connectionLabel = "Connecting…"
                case .connected:
                    self.connectionLabel = "Connected (awaiting pairing)"
                case .paired:
                    self.connectionLabel = "Paired and ready"
                    self.hasTrustedSession = true
                    self.client.sendStreamConfig(qualityMode: self.previewQualityMode, previewZoomLevel: self.previewZoomLevel)
                case let .failed(reason):
                    self.connectionLabel = "Failed"
                    self.lastError = reason
                    self.isThermalQualityOverrideActive = false
                    self.screenPreview.reset()
                    if self.hasTrustedSession,
                       self.pairingCode.isEmpty,
                       reason.localizedCaseInsensitiveContains("invalid pairing code") {
                        self.hasTrustedSession = false
                        self.client.disconnect(userInitiated: true)
                    }
                }
            }
            .store(in: &cancellables)

        h264Decoder.onSampleBuffer = { [weak self] sampleBuffer in
            Task { @MainActor [weak self] in
                self?.screenPreview.consumeDecodedSampleBuffer(sampleBuffer)
            }
        }

        h264Decoder.onDecodeLatency = { [weak self] latencyMs in
            Task { @MainActor [weak self] in
                self?.screenPreview.updateDecodeLatency(ms: latencyMs)
            }
        }

        client.onRemoteError = { [weak self] reason in
            self?.lastError = reason
        }

        client.onH264Config = { [weak self] configData in
            self?.h264Decoder.configure(with: configData)
        }

        client.onH264Frame = { [weak self] frameData in
            self?.h264Decoder.decode(framePayload: frameData)
        }

        client.onScreenFrame = { [weak self] frameData in
            guard let self else { return }
            self.screenPreview.consumeFrameData(frameData)
        }

        client.onCursorPosition = { [weak self] x, y in
            guard let self else { return }
            self.screenPreview.updateCursorPosition(x: x, y: y)
        }

        client.onThermalOverrideChanged = { [weak self] isActive in
            guard let self else { return }
            self.isThermalQualityOverrideActive = isActive
        }
    }

    func start() {
        browser.start()
    }

    func stop() {
        browser.stop()
        client.disconnect()
    }

    func connect() {
        guard let selectedService else {
            lastError = "No Mac host discovered. Keep the macOS app running on the same Wi-Fi."
            return
        }

        let codeToUse: String
        if pairingCode.count == 6 {
            codeToUse = pairingCode
        } else if pairingCode.isEmpty, hasTrustedSession {
            codeToUse = ""
        } else {
            lastError = "Pairing code must be 6 digits."
            return
        }

        lastError = nil
        client.connect(host: selectedService.host, port: selectedService.port, pairingCode: codeToUse)
    }

    func disconnect() {
        client.disconnect()
    }

    func toggleModifier(_ modifier: RemoteModifier) {
        if activeModifiers.contains(modifier) {
            activeModifiers.remove(modifier)
        } else {
            activeModifiers.insert(modifier)
        }
    }

    func clearModifiers() {
        activeModifiers.removeAll()
    }

    func handleCharacter(_ character: Character) {
        let value = String(character)
        let modifiers = Array(activeModifiers)

        if modifiers.isEmpty {
            if let shiftedBaseKey = shiftedBaseKey(for: character) {
                client.sendKey(shiftedBaseKey, modifiers: [.shift], action: .tap)
            } else {
                client.sendText(value)
            }
            return
        }

        let keyName = normalizeKeyCharacter(character)
        client.sendKey(keyName, modifiers: modifiers, action: .tap)
    }

    func handleBackspace() {
        client.sendKey(KeyboardNamedKey.backspace.rawValue, modifiers: Array(activeModifiers), action: .tap)
    }

    func handleReturn() {
        client.sendKey(KeyboardNamedKey.enter.rawValue, modifiers: Array(activeModifiers), action: .tap)
    }

    func sendNamedKey(_ key: KeyboardNamedKey) {
        client.sendKey(key.rawValue, modifiers: Array(activeModifiers), action: .tap)
    }

    func moveMouse(deltaX: Double, deltaY: Double) {
        client.sendMouseMove(deltaX: deltaX, deltaY: deltaY)
    }

    func clickMouse(button: MouseButton, action: KeyAction = .tap) {
        client.sendMouseClick(button: button, action: action)
    }

    func scrollMouse(deltaX: Double, deltaY: Double) {
        client.sendMouseScroll(scrollX: deltaX, scrollY: deltaY)
    }

    func setPreviewQualityMode(_ mode: PreviewQualityMode) {
        guard previewQualityMode != mode else { return }
        previewQualityMode = mode
        client.sendStreamConfig(qualityMode: mode, previewZoomLevel: previewZoomLevel)
    }

    func setPreviewZoomLevel(_ zoomLevel: Double) {
        let clamped = min(3.0, max(1.0, zoomLevel))
        guard abs(previewZoomLevel - clamped) > 0.01 else { return }
        previewZoomLevel = clamped
        client.sendStreamConfig(qualityMode: previewQualityMode, previewZoomLevel: previewZoomLevel)
    }

    func forgetTrustedSessionOnPhone() {
        hasTrustedSession = false
        pairingCode = ""
    }

    func forgetCurrentDeviceTrustOnMac() {
        client.sendForgetCurrentDeviceTrust()
        hasTrustedSession = false
        pairingCode = ""
    }

    private func shiftedBaseKey(for character: Character) -> String? {
        let value = String(character)

        if value.count == 1,
           let scalar = value.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar) {
            return value.lowercased()
        }

        let shiftedSymbolMap: [Character: String] = [
            "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/"
        ]

        return shiftedSymbolMap[character]
    }

    private func normalizeKeyCharacter(_ character: Character) -> String {
        if character == " " {
            return KeyboardNamedKey.space.rawValue
        }
        return String(character).lowercased()
    }
}
