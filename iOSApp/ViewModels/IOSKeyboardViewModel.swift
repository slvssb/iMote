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
    @Published var pointerProfile: PointerProfile = .edgeAssist
    @Published var areModifiersSticky: Bool = true
    @Published var keyRepeatInterval: Double = 0.08
    @Published private(set) var thermalStateLabel: String = "Nominal"

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

    var isPaired: Bool {
        if case .paired = client.state {
            return true
        }
        return false
    }

    var isTrustedAutoReconnect: Bool {
        hasTrustedSession && pairingCode.isEmpty
    }

    private let browser = BonjourServiceBrowser()
    private let client = IOSWebSocketClient()
    private let h264Decoder = H264FrameDecoder()
    private var cancellables: Set<AnyCancellable> = []

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
                    self.screenPreview.reset()
                case .connecting:
                    self.connectionLabel = "Connecting…"
                case .connected:
                    self.connectionLabel = "Connected (awaiting pairing)"
                case .paired:
                    self.connectionLabel = "Paired and ready"
                    self.hasTrustedSession = true
                    self.client.sendStreamConfig(qualityMode: self.previewQualityMode, pointerProfile: self.pointerProfile)
                case let .failed(reason):
                    self.connectionLabel = "Failed"
                    self.lastError = reason
                    self.screenPreview.reset()
                    if self.hasTrustedSession,
                       self.pairingCode.isEmpty,
                       reason.localizedCaseInsensitiveContains("invalid pairing code") {
                        self.hasTrustedSession = false
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

        client.onTelemetry = { [weak self] fps, captureWidth, bitrateScale, skipRatio in
            guard let self else { return }
            self.screenPreview.updateStreamTelemetry(
                serverFPS: fps,
                captureWidth: captureWidth,
                bitrateScale: bitrateScale,
                skipRatio: skipRatio
            )
        }

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleThermalStateChange()
            }
            .store(in: &cancellables)
        handleThermalStateChange()
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
            consumeOneShotModifiersIfNeeded()
            return
        }

        let keyName = normalizeKeyCharacter(character)
        client.sendKey(keyName, modifiers: modifiers, action: .tap)
        consumeOneShotModifiersIfNeeded()
    }

    func handleBackspace() {
        client.sendKey(KeyboardNamedKey.backspace.rawValue, modifiers: Array(activeModifiers), action: .tap)
        consumeOneShotModifiersIfNeeded()
    }

    func handleReturn() {
        client.sendKey(KeyboardNamedKey.enter.rawValue, modifiers: Array(activeModifiers), action: .tap)
        consumeOneShotModifiersIfNeeded()
    }

    func sendNamedKey(_ key: KeyboardNamedKey) {
        client.sendKey(key.rawValue, modifiers: Array(activeModifiers), action: .tap)
        consumeOneShotModifiersIfNeeded()
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
        client.sendStreamConfig(qualityMode: mode, pointerProfile: pointerProfile)
    }

    func setPointerProfile(_ profile: PointerProfile) {
        guard pointerProfile != profile else { return }
        pointerProfile = profile
        client.sendStreamConfig(qualityMode: previewQualityMode, pointerProfile: profile)
    }

    func setModifierStickiness(_ isSticky: Bool) {
        areModifiersSticky = isSticky
        if isSticky == false {
            activeModifiers.removeAll()
        }
    }

    func setKeyRepeatInterval(_ interval: Double) {
        keyRepeatInterval = min(max(interval, 0.04), 0.20)
    }

    func triggerQuickActionLockScreen() {
        client.sendKey("q", modifiers: [.control, .command], action: .tap)
    }

    func triggerQuickActionMissionControl() {
        client.sendKey(KeyboardNamedKey.upArrow.rawValue, modifiers: [.control], action: .tap)
    }

    func triggerQuickActionAppSwitcher() {
        client.sendKey(KeyboardNamedKey.tab.rawValue, modifiers: [.command], action: .tap)
    }

    func triggerQuickActionSpotlight() {
        client.sendKey(KeyboardNamedKey.space.rawValue, modifiers: [.command], action: .tap)
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

    private func consumeOneShotModifiersIfNeeded() {
        guard areModifiersSticky == false, activeModifiers.isEmpty == false else { return }
        activeModifiers.removeAll()
    }

    private func handleThermalStateChange() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            thermalStateLabel = "Nominal"
        case .fair:
            thermalStateLabel = "Fair"
        case .serious:
            thermalStateLabel = "Serious"
            if previewQualityMode != .balanced {
                setPreviewQualityMode(.balanced)
            }
        case .critical:
            thermalStateLabel = "Critical"
            if previewQualityMode != .balanced {
                setPreviewQualityMode(.balanced)
            }
        @unknown default:
            thermalStateLabel = "Unknown"
        }
    }
}
