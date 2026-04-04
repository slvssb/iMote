import Combine
import Foundation

@MainActor
final class IOSKeyboardViewModel: ObservableObject {
    enum ConnectionTargetMode: String, CaseIterable {
        case localDiscovery
        case manualAddress
    }

    enum HostPermissionRequirement {
        case accessibility
        case screenRecording
    }

    enum PermissionGatePhase {
        case idle
        case checking
        case checklist
    }

    struct HostPermissionChecklistState {
        var accessibilityGranted: Bool
        var screenRecordingGranted: Bool

        var allGranted: Bool {
            accessibilityGranted && screenRecordingGranted
        }
    }

    @Published var services: [DiscoveredService] = []
    @Published var selectedService: DiscoveredService?
    @Published var connectionTargetMode: ConnectionTargetMode = .localDiscovery
    @Published var manualHost = ""
    @Published var manualPortText = "8989"
    @Published var pairingCode = ""
    @Published var activeModifiers: Set<RemoteModifier> = []
    @Published var lastError: String?
    @Published var connectionLabel = "Disconnected"
    @Published var previewQualityMode: PreviewQualityMode = .ultra
    @Published var isThermalQualityOverrideActive = false
    @Published var audioCaptureSource: AudioCaptureSource = .systemOutput
    @Published private(set) var permissionGatePhase: PermissionGatePhase = .idle
    @Published private(set) var hostPermissionState = HostPermissionChecklistState(
        accessibilityGranted: false,
        screenRecordingGranted: false
    )
    @Published private(set) var hasCompletedPermissionGate = false

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

    var shouldShowPermissionGate: Bool {
        isPaired && hasCompletedPermissionGate == false && hasSeenMissingRequiredPermissions
    }

    var canContinueAfterPermissionGate: Bool {
        permissionGatePhase == .checklist && hostPermissionState.allGranted
    }

    private let browser = BonjourServiceBrowser()
    private let client = IOSWebSocketClient()
    private let h264Decoder = H264FrameDecoder()
    private let aacAudioPlayer = AACAudioPlayer()
    private var cancellables: Set<AnyCancellable> = []
    private var previewZoomLevel: Double = 1.0
    private var isUserInitiatedDisconnecting = false
    private var suppressExpectedDisconnectErrors = false
    private var permissionPollTask: Task<Void, Never>?
    private var hasSeenMissingRequiredPermissions = false

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

            }
            .store(in: &cancellables)

        client.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .disconnected:
                    self.connectionLabel = "Disconnected"
                    self.lastError = nil
                    self.isUserInitiatedDisconnecting = false
                    self.isThermalQualityOverrideActive = false
                    self.screenPreview.reset()
                    self.aacAudioPlayer.stop()
                    self.resetPermissionGate()
                case .connecting:
                    self.isUserInitiatedDisconnecting = false
                    self.suppressExpectedDisconnectErrors = false
                    self.connectionLabel = "Connecting…"
                    self.aacAudioPlayer.stop()
                    self.resetPermissionGate()
                case .connected:
                    self.isUserInitiatedDisconnecting = false
                    self.suppressExpectedDisconnectErrors = false
                    self.connectionLabel = "Connected (awaiting pairing)"
                case .paired:
                    self.isUserInitiatedDisconnecting = false
                    self.suppressExpectedDisconnectErrors = false
                    self.connectionLabel = "Paired and ready"
                    self.hasTrustedSession = true
                    self.client.sendStreamConfig(qualityMode: self.previewQualityMode, previewZoomLevel: self.previewZoomLevel)
                    self.client.sendAudioConfig(source: self.audioCaptureSource)
                    self.aacAudioPlayer.start()
                    self.beginPermissionGate()
                case let .failed(reason):
                    let normalizedReason = reason.localizedLowercase
                    if self.suppressExpectedDisconnectErrors,
                       (normalizedReason.contains("socket is not connected") ||
                        normalizedReason.contains("cancel")) {
                        self.connectionLabel = "Disconnected"
                        self.lastError = nil
                        return
                    }
                    self.connectionLabel = "Failed"
                    self.lastError = reason
                    self.isThermalQualityOverrideActive = false
                    self.screenPreview.reset()
                    self.aacAudioPlayer.stop()
                    self.resetPermissionGate()
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
            guard let self else { return }
            if self.suppressExpectedDisconnectErrors,
               (reason.localizedCaseInsensitiveContains("socket is not connected") ||
                reason.localizedCaseInsensitiveContains("cancel")) {
                return
            }
            if case .disconnected = self.client.state {
                return
            }
            self.lastError = reason
        }

        client.onH264Config = { [weak self] configData in
            self?.h264Decoder.configure(with: configData)
        }

        client.onH264Frame = { [weak self] frameData in
            self?.h264Decoder.decode(framePayload: frameData)
        }

        client.onAACConfig = { [weak self] configPayload in
            guard let self else { return }
            self.aacAudioPlayer.configure(with: configPayload)
        }

        client.onAACFrame = { [weak self] framePayload in
            guard let self else { return }
            self.aacAudioPlayer.enqueueFrame(framePayload)
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

        client.onPermissionStatus = { [weak self] accessibilityGranted, screenRecordingGranted in
            guard let self else { return }
            guard self.isPaired else { return }
            self.hostPermissionState = HostPermissionChecklistState(
                accessibilityGranted: accessibilityGranted,
                screenRecordingGranted: screenRecordingGranted
            )

            if self.hostPermissionState.allGranted {
                self.stopPermissionPolling()
                self.permissionGatePhase = .checklist

                // If host was already ready at first check, skip showing the permission gate.
                if self.hasSeenMissingRequiredPermissions == false {
                    self.hasCompletedPermissionGate = true
                    self.permissionGatePhase = .idle
                }
            } else {
                self.hasSeenMissingRequiredPermissions = true
                self.permissionGatePhase = .checklist
                self.startPermissionPollingIfNeeded()
            }
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
        let host: String
        let port: Int

        switch connectionTargetMode {
        case .localDiscovery:
            guard let selectedService else {
                lastError = "No Mac host discovered. Keep the macOS app running on the same Wi-Fi."
                return
            }
            host = selectedService.host
            port = selectedService.port
        case .manualAddress:
            let trimmedHost = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedHost.isEmpty == false else {
                lastError = "Enter a remote host or IP address."
                return
            }
            guard let parsedPort = Int(manualPortText), (1...65_535).contains(parsedPort) else {
                lastError = "Port must be between 1 and 65535."
                return
            }
            host = trimmedHost
            port = parsedPort
        }

        isUserInitiatedDisconnecting = false
        suppressExpectedDisconnectErrors = false

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
        client.connect(host: host, port: port, pairingCode: codeToUse)
    }

    func disconnect() {
        isUserInitiatedDisconnecting = true
        suppressExpectedDisconnectErrors = true
        lastError = nil
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

    func sendModifierTap(_ modifier: RemoteModifier) {
        client.sendKey(modifier.rawValue, modifiers: [], action: .tap)
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

    func sendNamedKey(_ key: KeyboardNamedKey, modifiers: [RemoteModifier]) {
        client.sendKey(key.rawValue, modifiers: modifiers, action: .tap)
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

    func setAudioCaptureSource(_ source: AudioCaptureSource) {
        guard audioCaptureSource != source else { return }
        audioCaptureSource = source
        client.sendAudioConfig(source: source)
    }

    func requestStreamResync() {
        guard isPaired else { return }
        client.sendStreamResync()
    }

    func requestLocalPreviewDecoderResync() {
        h264Decoder.forceResyncUsingLastConfig()
        screenPreview.displayBridge.flush()
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

    func refreshHostPermissionStatus() {
        guard isPaired else { return }
        client.requestPermissionStatus()
    }

    func requestHostPermissionFix(_ requirement: HostPermissionRequirement) {
        guard isPaired else { return }
        switch requirement {
        case .accessibility:
            client.sendPermissionAction(.requestAccessibilityPrompt)
            client.sendPermissionAction(.openAccessibilitySettings)
        case .screenRecording:
            client.sendPermissionAction(.requestScreenRecordingPrompt)
            client.sendPermissionAction(.openScreenRecordingSettings)
        }
        refreshHostPermissionStatus()
    }

    func completePermissionGate() {
        guard canContinueAfterPermissionGate else { return }
        hasCompletedPermissionGate = true
        stopPermissionPolling()
    }

    private func beginPermissionGate() {
        hasCompletedPermissionGate = false
        hasSeenMissingRequiredPermissions = false
        hostPermissionState = HostPermissionChecklistState(
            accessibilityGranted: false,
            screenRecordingGranted: false
        )
        permissionGatePhase = .checking
        stopPermissionPolling()
        client.requestPermissionStatus()
    }

    private func resetPermissionGate() {
        hasCompletedPermissionGate = false
        hasSeenMissingRequiredPermissions = false
        permissionGatePhase = .idle
        hostPermissionState = HostPermissionChecklistState(
            accessibilityGranted: false,
            screenRecordingGranted: false
        )
        stopPermissionPolling()
    }

    private func startPermissionPollingIfNeeded() {
        guard permissionPollTask == nil else { return }
        permissionPollTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard self.isPaired, self.hasCompletedPermissionGate == false else { return }
                if self.hostPermissionState.allGranted {
                    return
                }
                self.client.requestPermissionStatus()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
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
