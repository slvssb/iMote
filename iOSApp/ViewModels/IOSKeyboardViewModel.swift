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
    @Published private(set) var savedHosts: [SavedRemoteHost] = []
    @Published var pairingCode = ""
    @Published var activeModifiers: Set<RemoteModifier> = []
    @Published var lastError: String?
    @Published var connectionLabel = "Disconnected"
    @Published var previewQualityMode: PreviewQualityMode = .ultra
    @Published var isThermalQualityOverrideActive = false
    @Published var audioCaptureSource: AudioCaptureSource = .off
    @Published private(set) var permissionGatePhase: PermissionGatePhase = .idle
    @Published private(set) var hostPermissionState = HostPermissionChecklistState(
        accessibilityGranted: false,
        screenRecordingGranted: false
    )
    @Published private(set) var hasCompletedPermissionGate = false
    @Published var pairedHostFingerprint: String?
    @Published var pairedHostFingerprintIsNew = false

    let screenPreview = ScreenPreviewState()

    var isConnected: Bool {
        switch client.state {
        case .connected, .securing, .paired:
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
        hasTrustedSessionLocally && pairingCode.isEmpty
    }

    var hasTrustedSessionLocally: Bool {
        _ = trustedEndpointStamp
        return TrustedHostStore.isTrusted(endpointKeys: currentEndpointKeys())
    }

    var localSigningFingerprint: String {
        client.localSigningFingerprint
    }

    var shouldShowPermissionGate: Bool {
        isPaired && hasCompletedPermissionGate == false && hasSeenMissingRequiredPermissions
    }

    var canContinueAfterPermissionGate: Bool {
        permissionGatePhase == .checklist && hostPermissionState.accessibilityGranted
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

    private let connectionModeKey = "remoteKeyboard.connectionTargetMode"
    private let manualHostKey = "remoteKeyboard.manualHost"
    private let manualPortKey = "remoteKeyboard.manualPort"
    @Published private var trustedEndpointStamp = 0

    init() {
        let defaults = UserDefaults.standard
        if let rawMode = defaults.string(forKey: connectionModeKey),
           let mode = ConnectionTargetMode(rawValue: rawMode) {
            connectionTargetMode = mode
        }
        if let storedHost = defaults.string(forKey: manualHostKey) {
            manualHost = storedHost
        }
        if let storedPort = defaults.string(forKey: manualPortKey), storedPort.isEmpty == false {
            manualPortText = storedPort
        }
        savedHosts = SavedRemoteHostStore.load()
        defaults.removeObject(forKey: "remoteKeyboard.trustedSession")

        client.onTrustedEndpointsChanged = { [weak self] in
            self?.trustedEndpointStamp += 1
        }

        browser.$services
            .receive(on: RunLoop.main)
            .sink { [weak self] updated in
                guard let self else { return }
                self.services = updated
                if self.selectedService == nil {
                    self.selectedService = updated.first
                } else if let selected = self.selectedService {
                    if let refreshed = updated.first(where: { service in
                        service.name == selected.name && service.port == selected.port
                    }) {
                        self.selectedService = refreshed
                    } else {
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
                case .securing:
                    self.isUserInitiatedDisconnecting = false
                    self.suppressExpectedDisconnectErrors = false
                    self.connectionLabel = "Connected (establishing E2E…)"
                case .paired:
                    self.isUserInitiatedDisconnecting = false
                    self.suppressExpectedDisconnectErrors = false
                    self.connectionLabel = "Paired and ready (E2E)"
                    self.client.sendStreamConfig(qualityMode: self.previewQualityMode, previewZoomLevel: self.previewZoomLevel)
                    self.client.sendAudioConfig(source: self.audioCaptureSource)
                    self.client.sendStreamResync()
                    self.updateAudioPlaybackState()
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

        client.onHostCaptureStatusChanged = { [weak self] routeLabel, displayCount, isActive in
            guard let self else { return }
            self.screenPreview.updateHostCaptureStatus(
                routeLabel: routeLabel,
                displayCount: displayCount,
                isActive: isActive
            )
        }

        client.onHostFingerprintPinned = { [weak self] fingerprint, isNew in
            guard let self else { return }
            self.pairedHostFingerprint = fingerprint
            self.pairedHostFingerprintIsNew = isNew
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
            switch RemoteHostAddress.parse(hostField: manualHost, portField: manualPortText) {
            case let .failure(failure):
                lastError = failure.message
                return
            case let .success(address):
                host = address.host
                port = address.port
                manualHost = address.host
                manualPortText = String(address.port)
                rememberRemoteHost(address)
            }
        }

        isUserInitiatedDisconnecting = false
        suppressExpectedDisconnectErrors = false

        let endpointKeys = currentEndpointKeys()
        let codeToUse: String
        if pairingCode.count == 6 {
            codeToUse = pairingCode
        } else if pairingCode.isEmpty, TrustedHostStore.isTrusted(endpointKeys: endpointKeys) {
            codeToUse = ""
        } else {
            lastError = "Pairing code must be 6 digits."
            return
        }

        lastError = nil
        noteConnectionDraftChanged()
        client.connect(host: host, port: port, pairingCode: codeToUse, trustedEndpointKeys: endpointKeys)
    }

    func currentEndpointKeys() -> [String] {
        switch connectionTargetMode {
        case .localDiscovery:
            guard let selectedService else { return [] }
            return [
                TrustedHostStore.bonjourKey(name: selectedService.name, port: selectedService.port),
                TrustedHostStore.endpointKey(host: selectedService.host, port: selectedService.port)
            ]
        case .manualAddress:
            guard case let .success(address) = RemoteHostAddress.parse(hostField: manualHost, portField: manualPortText) else {
                return []
            }
            return [TrustedHostStore.endpointKey(host: address.host, port: address.port)]
        }
    }

    func selectSavedHost(_ host: SavedRemoteHost) {
        connectionTargetMode = .manualAddress
        manualHost = host.host
        manualPortText = String(host.port)
        noteConnectionDraftChanged()
    }

    func forgetSavedHost(_ host: SavedRemoteHost) {
        savedHosts.removeAll { $0.id == host.id }
        SavedRemoteHostStore.save(savedHosts)
    }

    func noteConnectionDraftChanged() {
        let defaults = UserDefaults.standard
        defaults.set(connectionTargetMode.rawValue, forKey: connectionModeKey)
        defaults.set(manualHost, forKey: manualHostKey)
        defaults.set(manualPortText, forKey: manualPortKey)
    }

    private func rememberRemoteHost(_ address: RemoteHostAddress) {
        var hosts = savedHosts
        if let index = hosts.firstIndex(where: { existing in
            existing.host.caseInsensitiveCompare(address.host) == .orderedSame && existing.port == address.port
        }) {
            hosts[index].host = address.host
            hosts[index].port = address.port
            hosts[index].lastUsedAt = Date()
        } else {
            hosts.append(SavedRemoteHost(id: UUID(), host: address.host, port: address.port, lastUsedAt: Date()))
        }
        hosts.sort { $0.lastUsedAt > $1.lastUsedAt }
        if hosts.count > SavedRemoteHostStore.limit {
            hosts = Array(hosts.prefix(SavedRemoteHostStore.limit))
        }
        savedHosts = hosts
        SavedRemoteHostStore.save(hosts)
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
        let modifiers = Array(activeModifiers)
        if character == " " {
            client.sendKey(KeyboardNamedKey.space.rawValue, modifiers: modifiers, action: .tap)
            return
        }

        let shortcutModifiers = modifiers.filter { $0 != .shift }
        if shortcutModifiers.isEmpty == false, character.isLetter {
            client.sendKey(String(character).lowercased(), modifiers: modifiers, action: .tap)
            return
        }

        if modifiers.isEmpty, shouldSendAsUnicodeText(character) {
            client.sendText(String(character))
            return
        }

        client.sendKey(String(character), modifiers: modifiers, action: .tap)
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
        client.sendMouseMove(deltaX: deltaX, deltaY: deltaY, modifiers: Array(activeModifiers))
    }

    func clickMouse(button: MouseButton, action: KeyAction = .tap) {
        client.sendMouseClick(button: button, modifiers: Array(activeModifiers), action: action)
    }

    func scrollMouse(deltaX: Double, deltaY: Double) {
        client.sendMouseScroll(scrollX: deltaX, scrollY: deltaY, modifiers: Array(activeModifiers))
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
        updateAudioPlaybackState()
    }

    private func updateAudioPlaybackState() {
        if audioCaptureSource == .off {
            aacAudioPlayer.stop()
        } else if isPaired {
            aacAudioPlayer.start()
        }
    }

    func notePreviewDidNotStart() {
        guard screenPreview.hasFrame == false else { return }
        screenPreview.noteCaptureDidNotStart()
        if lastError == nil {
            lastError = "Screen preview did not start. Keyboard and trackpad are ready. Check Screen Recording on the Mac."
        }
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
        forgetStoredTrust(matching: currentEndpointKeys())
    }

    func forgetCurrentDeviceTrustOnMac() async -> Bool {
        let endpointKeys = client.connectedEndpointKeys
        let sent = await client.sendForgetCurrentDeviceTrust()
        guard sent else {
            if lastError == nil {
                lastError = "Could not tell the Mac to forget this iPhone. Still connected."
            }
            return false
        }
        forgetStoredTrust(matching: endpointKeys)
        return true
    }

    private func forgetStoredTrust(matching endpointKeys: [String]) {
        let removed = TrustedHostStore.forgetHosts(matching: endpointKeys)
        for signingKey in removed {
            client.clearHostPins(matchingSigningKey: signingKey)
        }
        pairingCode = ""
        pairedHostFingerprint = nil
        pairedHostFingerprintIsNew = false
        trustedEndpointStamp += 1
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

    private func shouldSendAsUnicodeText(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return true
        }
        if CharacterSet.lowercaseLetters.contains(scalar) { return true }
        if scalar.value < 0x20 || scalar.value > 0x7E { return true }
        return false
    }
}
