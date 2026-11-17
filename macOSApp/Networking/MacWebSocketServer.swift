import AppKit
import CryptoKit
import CoreGraphics
import Foundation
import Network

final class MacWebSocketServer: @unchecked Sendable {
    private static let frameIntervalNanos: UInt64 = 16_666_667
    private static let adaptiveWindowTicks = 60

    struct ClientSnapshot: Sendable {
        let id: UUID
        let deviceName: String?
    }

    struct HostDisplayCatalogSnapshot: Sendable {
        var routeLabel: String
        var displays: [HostDisplayInfo]
        var capturedDisplayID: CGDirectDisplayID
        var selectedDisplayID: CGDirectDisplayID
        var virtualDisplayWhenHeadless: Bool
    }

    var onStateChange: ((String) -> Void)?
    var onClientsChange: (([ClientSnapshot]) -> Void)?
    var onRuntimeError: ((String) -> Void)?
    var onCaptureRouteChange: ((String) -> Void)?
    var onDisplayCatalogChange: ((HostDisplayCatalogSnapshot) -> Void)?

    private struct ClientContext {
        let id: UUID
        let connection: NWConnection
        var token: String?
        var deviceName: String?
        var secureSession: SecureSession?
    }

    private struct SecureSession {
        let clientDeviceID: String
        let controlKey: SymmetricKey
        let mediaKey: SymmetricKey
    }

    private let pairingManager: PairingManager
    private let injector: KeyboardInjector
    private let accessibilityPermissionManager: AccessibilityPermissionManager
    private let screenCaptureProvider = MacScreenCaptureProvider()
    private let h264Encoder = H264FrameEncoder()
    private let aacEncoder = AACAudioEncoder()
    private let virtualDisplayManager = VirtualDisplayManager()
    private let sessionPower = RemoteSessionPowerAssertion()
    private let queue = DispatchQueue(label: "remote.keyboard.mac.ws")
    private var thermalObserver: NSObjectProtocol?
    private var workspaceSleepObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var workspaceScreensSleepObserver: NSObjectProtocol?
    private var workspaceScreensWakeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    private var listener: NWListener?
    private var listenerPort: UInt16 = 8989
    private var clients: [UUID: ClientContext] = [:]
    private var frameTimer: DispatchSourceTimer?
    private var isFrameCaptureInFlight = false
    private var consecutiveFrameFailures = 0
    private var userSelectedQualityMode: PreviewQualityMode = .ultra
    private var effectiveQualityMode: PreviewQualityMode = .ultra
    private var requestedPreviewZoomLevel: Double = 1.0
    private var selectedAudioCaptureSource: AudioCaptureSource = .off
    private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var isThermalOverrideActive = false
    private var previewCaptureMaxWidth: CGFloat = 1920
    private var adaptiveBitrateScale: Double = 1.0
    private var adaptiveWindowTickCount = 0
    private var adaptiveWindowSkippedCount = 0
    private var adaptiveWindowEncodedCount = 0
    private var streamStatusHeartbeatTickCount = 0
    private var audioDebugSentConfigCount = 0
    private var audioDebugSentFrameCount = 0
    private var localSigningPrivateKey = MacWebSocketServer.loadOrCreateSigningPrivateKey()
    private let hostDeviceID = MacWebSocketServer.loadOrCreateHostDeviceID()
    private var isSystemSleeping = false
    private var isDisplaySleeping = false
    private var isWakeRecoveryInProgress = false
    private var lastCaptureRecoveryAttemptAt: Date?
    private var recoveryBurstGeneration: UInt64 = 0
    private var lastPublishedCaptureRouteLabel: String = "Unknown"
    private var lastPublishedCaptureActive: Bool?
    private var isListenerRunning = false
    private var virtualDisplayWhenHeadless = HostDisplayPreferences.virtualDisplayWhenHeadless
    private var preferredCaptureDisplayID = HostDisplayPreferences.selectedDisplayID
    private var preferredCaptureIdentity = HostDisplayPreferences.selectedIdentity
    private var cachedDisplayNames: [CGDirectDisplayID: String] = [:]
    private var cachedDisplayRecords: [HostDisplayRecord] = []
    private var lastPointerDisplayID: CGDirectDisplayID = 0
    private var lastPointerBounds: CGRect = .zero
    private var lastCaptureSummary: String = "Unknown"
    private var lastDisplayWakeAttemptAt: Date?

    private enum BinaryPacketMarker {
        static let encryptedMedia: UInt8 = 0x7E
        static let h264Config: UInt8 = 0x10
        static let h264Frame: UInt8 = 0x11
        static let aacConfig: UInt8 = 0x20
        static let aacFrame: UInt8 = 0x21
    }

    init(
        pairingManager: PairingManager,
        injector: KeyboardInjector,
        accessibilityPermissionManager: AccessibilityPermissionManager
    ) {
        self.pairingManager = pairingManager
        self.injector = injector
        self.accessibilityPermissionManager = accessibilityPermissionManager

        h264Encoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.queue.async {
                let pairedClientIDs = self.clients.compactMap { id, context in
                    (context.token == nil || context.secureSession == nil) ? nil : id
                }
                for id in pairedClientIDs {
                    self.sendBinaryFrame(packet, to: id)
                }
            }
        }

        aacEncoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.queue.async {
                if let marker = packet.first {
                    if marker == AACAudioEncoder.configMarker {
                        self.audioDebugSentConfigCount += 1
                        print("[AudioDebug][mac] sent config #\(self.audioDebugSentConfigCount)")
                    } else if marker == AACAudioEncoder.frameMarker {
                        self.audioDebugSentFrameCount += 1
                        if self.audioDebugSentFrameCount % 120 == 0 {
                            print("[AudioDebug][mac] sent frames=\(self.audioDebugSentFrameCount)")
                        }
                    }
                }
                let pairedClientIDs = self.clients.compactMap { id, context in
                    (context.token == nil || context.secureSession == nil) ? nil : id
                }
                for id in pairedClientIDs {
                    self.sendBinaryFrame(packet, to: id)
                }
            }
        }

        Task {
            await screenCaptureProvider.setAudioSampleHandler { [weak self] sampleBuffer in
                self?.handleAudioSampleBuffer(sampleBuffer)
            }
            await screenCaptureProvider.setAudioCaptureSource(self.selectedAudioCaptureSource)
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            self.queue.async {
                self.handleThermalStateChange(state)
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleSystemWillSleep()
            }
        }

        workspaceWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleSystemDidWake()
            }
        }

        workspaceScreensSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleDisplaysDidSleep()
            }
        }

        workspaceScreensWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleDisplaysDidWake()
            }
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleScreenParametersDidChange()
            }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let workspaceSleepObserver {
            workspaceCenter.removeObserver(workspaceSleepObserver)
        }
        if let workspaceWakeObserver {
            workspaceCenter.removeObserver(workspaceWakeObserver)
        }
        if let workspaceScreensSleepObserver {
            workspaceCenter.removeObserver(workspaceScreensSleepObserver)
        }
        if let workspaceScreensWakeObserver {
            workspaceCenter.removeObserver(workspaceScreensWakeObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func start(port: UInt16 = 8989) throws {
        listenerPort = port
        if listener != nil {
            return
        }

        guard let listenPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(
                domain: "MacWebSocketServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"]
            )
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let wsListener = try NWListener(using: parameters, on: listenPort)
        wsListener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac Keyboard", type: "_rkbd._tcp")

        wsListener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
            guard let self else { return }
            let description: String
            switch state {
            case .ready:
                description = "Listening on port \(port)"
            case .failed(let error):
                description = "Listener failed: \(error.localizedDescription)"
            case .cancelled:
                description = "Stopped"
            case .waiting(let error):
                description = "Waiting: \(error.localizedDescription)"
            default:
                description = "Starting…"
            }

            Task { @MainActor in
                self.onStateChange?(description)
            }
        }

        wsListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener = wsListener
        isListenerRunning = true
        wsListener.start(queue: queue)
        queue.async { [weak self] in
            self?.syncHeadlessDisplay()
        }
        startFrameBroadcasting()
    }

    func stop() {
        isListenerRunning = false
        queue.async { [weak self] in
            guard let self else { return }
            self.clients.values.forEach { context in
                context.connection.cancel()
            }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.stopFrameBroadcasting()
            Task { [weak self] in
                await self?.screenCaptureProvider.stopCapture()
            }
            self.h264Encoder.stop()
            self.aacEncoder.stop()
            self.sessionPower.setRemoteSessionActive(false)
            self.virtualDisplayManager.tearDown()
            self.publishClients()
        }
    }

    func setVirtualDisplayWhenHeadless(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.isListenerRunning else { return }
            self.virtualDisplayWhenHeadless = enabled
            HostDisplayPreferences.save(virtualDisplayWhenHeadless: enabled)
            self.syncHeadlessDisplay()
            self.scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display setting change")
            self.sendStreamStatusToAllPairedClients()
        }
    }

    func selectCaptureDisplay(id: UInt32) {
        queue.async { [weak self] in
            guard let self, self.isListenerRunning else { return }
            self.preferredCaptureDisplayID = id
            let identity = self.cachedDisplayRecords.first { $0.info.id == id }?.identity
            self.preferredCaptureIdentity = identity?.isSpecific == true ? identity : nil
            HostDisplayPreferences.saveSelection(displayID: id, identity: self.preferredCaptureIdentity)
            self.pushCaptureSelectionPolicy()
            self.scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display selection")
            self.publishDisplayCatalog()
            self.sendStreamStatusToAllPairedClients()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let context = ClientContext(id: id, connection: connection, token: nil, deviceName: nil, secureSession: nil)
        clients[id] = context
        publishClients()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext(for: id)
            case .failed, .cancelled:
                self.disconnect(id: id)
            default:
                break
            }
        }

        connection.start(queue: queue)

        Task { @MainActor in
            self.onStateChange?("Client connected")
        }
    }

    private func disconnect(id: UUID) {
        if let removed = clients.removeValue(forKey: id) {
            pairingManager.revoke(token: removed.token)
        }
        updateRemoteSessionPower()
        publishClients()
    }

    private func receiveNext(for id: UUID) {
        guard let context = clients[id] else { return }
        context.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.reportError("Receive failed: \(error.localizedDescription)")
                self.disconnect(id: id)
                return
            }

            guard let data else {
                // Peer closed cleanly; tear down this client context so reconnects are accepted cleanly.
                self.disconnect(id: id)
                return
            }

            if data.isEmpty == false {
                self.handlePayload(data, from: id)
            }

            if self.clients[id] != nil {
                self.receiveNext(for: id)
            }
        }
    }

    private func handlePayload(_ data: Data, from id: UUID) {
        guard let message = try? RemoteProtocolCodec.decode(data) else {
            send(.error("Malformed JSON payload"), to: id)
            return
        }

        if message.type == .secureControl {
            handleSecureControl(message, from: id)
            return
        }

        handleDecodedMessage(message, from: id, isFromSecureChannel: false)
    }

    private func handleDecodedMessage(_ message: RemoteMessage, from id: UUID, isFromSecureChannel: Bool) {
        switch message.type {
        case .pair:
            handlePair(message, from: id)
        case .e2eHello:
            handleE2EHello(message, from: id)
        case .text:
            if isFromSecureChannel { handleText(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .key:
            if isFromSecureChannel { handleKey(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .mouseMove:
            if isFromSecureChannel { handleMouseMove(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .mouseClick:
            if isFromSecureChannel { handleMouseClick(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .mouseScroll:
            if isFromSecureChannel { handleMouseScroll(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .streamConfig:
            if isFromSecureChannel { handleStreamConfig(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .streamResync:
            if isFromSecureChannel { handleStreamResync(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .audioConfig:
            if isFromSecureChannel { handleAudioConfig(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .permissionStatusRequest:
            if isFromSecureChannel { handlePermissionStatusRequest(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .permissionAction:
            if isFromSecureChannel { handlePermissionAction(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .trustControl:
            if isFromSecureChannel { handleTrustControl(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .displayControl:
            if isFromSecureChannel { handleDisplayControl(message, from: id) } else { send(.error("Secure channel required"), to: id) }
        case .ping:
            send(RemoteMessage(type: .pong), to: id)
        default:
            break
        }
    }

    private func handleSecureControl(_ message: RemoteMessage, from id: UUID) {
        guard authorize(id: id, token: message.token),
              let context = clients[id],
              let secureSession = context.secureSession else {
            send(.error("Unauthorized secure control session"), to: id)
            return
        }
        guard let payloadBase64 = message.securePayload,
              let combined = Data(base64Encoded: payloadBase64) else {
            send(.error("Malformed secure control payload"), to: id)
            return
        }

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
            let plaintext = try ChaChaPoly.open(sealedBox, using: secureSession.controlKey)
            let inner = try RemoteProtocolCodec.decode(plaintext)
            guard inner.type != .secureControl else {
                send(.error("Nested secure control payload is not allowed"), to: id)
                return
            }
            handleDecodedMessage(inner, from: id, isFromSecureChannel: true)
        } catch {
            send(.error("Unable to decrypt secure control payload"), to: id)
        }
    }

    private func handlePair(_ message: RemoteMessage, from id: UUID) {
        let submitted = message.code ?? ""
        let result = pairingManager.pair(code: submitted, deviceID: message.deviceID)
        guard var context = clients[id] else { return }
        if result.success, let token = result.token {
            context.token = token
            context.deviceName = message.deviceName
            context.secureSession = nil
            clients[id] = context
            send(.pairAck(success: true, token: token, reason: nil), to: id, deviceIDOverride: hostDeviceID)
            updateRemoteSessionPower()
            syncHeadlessDisplay()
            sendStreamStatus(to: id)
            sendPermissionStatus(to: id)
            publishClients()
            scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after iPhone connected")
        } else {
            send(.pairAck(success: false, token: nil, reason: result.reason), to: id)
        }
    }

    private func handleE2EHello(_ message: RemoteMessage, from id: UUID) {
        guard authorize(id: id, token: message.token), let token = message.token else {
            send(.error("Unauthorized secure handshake"), to: id)
            return
        }
        guard let clientDeviceID = message.deviceID,
              let clientSigningKeyBase64 = message.signingPublicKey,
              let clientEphemeralBase64 = message.ephemeralPublicKey,
              let signatureBase64 = message.signature,
              let clientSigningKeyData = Data(base64Encoded: clientSigningKeyBase64),
              let clientEphemeralData = Data(base64Encoded: clientEphemeralBase64),
              let signatureData = Data(base64Encoded: signatureBase64) else {
            send(.error("Malformed secure handshake payload"), to: id)
            return
        }

        guard pairingManager.verifyOrPinSigningKey(deviceID: clientDeviceID, signingPublicKeyBase64: clientSigningKeyBase64) else {
            send(.error("Client identity key mismatch"), to: id)
            return
        }

        do {
            let clientSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: clientSigningKeyData)
            let signaturePayload = Self.signaturePayload(token: token, deviceID: clientDeviceID, ephemeralPublicKey: clientEphemeralData)
            guard clientSigningKey.isValidSignature(signatureData, for: signaturePayload) else {
                send(.error("Invalid secure handshake signature"), to: id)
                return
            }

            let hostEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            let hostEphemeralPublicData = hostEphemeralPrivateKey.publicKey.rawRepresentation
            let clientEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientEphemeralData)
            let sharedSecret = try hostEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: clientEphemeralPublicKey)
            let salt = Data(token.utf8)
            let controlKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("iMote.e2e.control.v1".utf8),
                outputByteCount: 32
            )
            let mediaKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("iMote.e2e.media.v1".utf8),
                outputByteCount: 32
            )

            guard var context = clients[id] else { return }
            context.secureSession = SecureSession(clientDeviceID: clientDeviceID, controlKey: controlKey, mediaKey: mediaKey)
            clients[id] = context
            // Trigger bootstrap media packets only after secure transport exists,
            // otherwise config/keyframe can be emitted before this client can receive them.
            h264Encoder.requestStreamResync()
            aacEncoder.requestStreamResync()

            let hostSignaturePayload = Self.signaturePayload(token: token, deviceID: hostDeviceID, ephemeralPublicKey: hostEphemeralPublicData)
            let hostSignature = try localSigningPrivateKey.signature(for: hostSignaturePayload)
            send(.e2eHelloAck(
                deviceID: hostDeviceID,
                signingPublicKey: localSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
                ephemeralPublicKey: hostEphemeralPublicData.base64EncodedString(),
                signature: hostSignature.base64EncodedString(),
                token: token
            ), to: id)
            sendStreamStatus(to: id)
            publishClients()
        } catch {
            send(.error("Failed to establish secure channel"), to: id)
        }
    }

    private func handleText(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        guard assertHostPermissionsForControl(to: id) else { return }
        guard let value = message.value else { return }
        do {
            try injector.injectText(value)
        } catch {
            send(.error(error.localizedDescription), to: id)
        }
    }

    private func handleKey(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        guard assertHostPermissionsForControl(to: id) else { return }
        guard let key = message.key else { return }
        let action = message.action ?? .tap
        let modifiers = message.modifiers ?? []
        do {
            try injector.injectKey(key: key, modifiers: modifiers, action: action)
        } catch {
            send(.error(error.localizedDescription), to: id)
        }
    }

    private func handleMouseMove(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        guard assertHostPermissionsForControl(to: id) else { return }

        let deltaX = message.deltaX ?? 0
        let deltaY = message.deltaY ?? 0
        let modifiers = message.modifiers ?? []
        guard deltaX != 0 || deltaY != 0 else { return }

        do {
            try injector.injectMouseMove(deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
        } catch {
            send(.error(error.localizedDescription), to: id)
        }
    }

    private func handleMouseClick(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        guard assertHostPermissionsForControl(to: id) else { return }

        let action = message.action ?? .tap
        let button = message.button ?? .left
        let modifiers = message.modifiers ?? []

        do {
            try injector.injectMouseClick(button: button, modifiers: modifiers, action: action)
        } catch {
            send(.error(error.localizedDescription), to: id)
        }
    }

    private func handleMouseScroll(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        guard assertHostPermissionsForControl(to: id) else { return }

        let scrollX = message.scrollX ?? 0
        let scrollY = message.scrollY ?? 0
        let modifiers = message.modifiers ?? []
        guard scrollX != 0 || scrollY != 0 else { return }

        do {
            try injector.injectMouseScroll(scrollX: scrollX, scrollY: scrollY, modifiers: modifiers)
        } catch {
            send(.error(error.localizedDescription), to: id)
        }
    }

    private func handleStreamConfig(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }

        guard let mode = message.qualityMode else { return }
        userSelectedQualityMode = mode
        if let zoomLevel = message.previewZoomLevel {
            requestedPreviewZoomLevel = min(max(zoomLevel, 1.0), 3.0)
        }
        applyEffectiveQualityMode()
    }

    private func handleStreamResync(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }

        h264Encoder.requestStreamResync()
        aacEncoder.requestStreamResync()
    }

    private func handleAudioConfig(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }

        guard let source = message.audioSource else { return }
        selectedAudioCaptureSource = source
        Task {
            await screenCaptureProvider.setAudioCaptureSource(source)
        }
        aacEncoder.requestStreamResync()
    }

    private func handlePermissionStatusRequest(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        sendPermissionStatus(to: id)
    }

    private func handlePermissionAction(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
        guard let action = message.permissionAction else { return }

        switch action {
        case .requestAccessibilityPrompt:
            _ = accessibilityPermissionManager.request(prompt: true)
        case .requestScreenRecordingPrompt:
            _ = CGRequestScreenCaptureAccess()
        case .openAccessibilitySettings:
            openSystemSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .openScreenRecordingSettings:
            openSystemSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }

        sendPermissionStatus(to: id)
    }

    private func handleTrustControl(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }

        guard let action = message.trustAction else { return }
        switch action {
        case .forgetCurrentDevice:
            guard let deviceID = message.deviceID, deviceID.isEmpty == false else {
                send(.error("Missing device identifier for trust action"), to: id)
                return
            }
            pairingManager.removeTrustedDevice(deviceID: deviceID)
        }
    }

    private func handleDisplayControl(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }

        if let enabled = message.virtualDisplayWhenHeadless {
            virtualDisplayWhenHeadless = enabled
            HostDisplayPreferences.save(virtualDisplayWhenHeadless: enabled)
        }
        if let displayID = message.displayID {
            preferredCaptureDisplayID = displayID
            let identity = cachedDisplayRecords.first { $0.info.id == displayID }?.identity
            preferredCaptureIdentity = identity?.isSpecific == true ? identity : nil
            HostDisplayPreferences.saveSelection(displayID: displayID, identity: preferredCaptureIdentity)
        }

        syncHeadlessDisplay()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display selection")
        sendStreamStatus(to: id)
    }

    private func authorize(id: UUID, token: String?) -> Bool {
        guard let context = clients[id] else {
            return false
        }
        guard let token else {
            return false
        }
        guard context.token == token else {
            return false
        }
        return pairingManager.validate(token: token)
    }

    private func send(_ message: RemoteMessage, to id: UUID, deviceIDOverride: String? = nil) {
        var message = message
        if let deviceIDOverride {
            message.deviceID = deviceIDOverride
        }
        guard let payload = try? RemoteProtocolCodec.encode(message) else {
            return
        }
        sendBinaryFrame(payload, to: id)
    }

    private func sendBinaryFrame(_ payload: Data, to id: UUID) {
        guard let context = clients[id] else {
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let contentContext = NWConnection.ContentContext(
            identifier: "remoteKeyboard",
            metadata: [metadata]
        )
        let outboundPayload: Data
        if let secureSession = context.secureSession, Self.isMediaPacket(payload) {
            do {
                let sealedBox = try ChaChaPoly.seal(payload, using: secureSession.mediaKey)
                var packet = Data([BinaryPacketMarker.encryptedMedia])
                packet.append(sealedBox.combined)
                outboundPayload = packet
            } catch {
                reportError("Failed to encrypt media packet")
                return
            }
        } else {
            outboundPayload = payload
        }

        context.connection.send(
            content: outboundPayload,
            contentContext: contentContext,
            isComplete: true,
            completion: .idempotent
        )
    }

    private static func isMediaPacket(_ payload: Data) -> Bool {
        guard let marker = payload.first else { return false }
        return marker == BinaryPacketMarker.h264Config ||
            marker == BinaryPacketMarker.h264Frame ||
            marker == BinaryPacketMarker.aacConfig ||
            marker == BinaryPacketMarker.aacFrame
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

    private static func loadOrCreateHostDeviceID() -> String {
        let key = "remoteKeyboard.mac.hostDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key), existing.isEmpty == false {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private static func loadOrCreateSigningPrivateKey() -> Curve25519.Signing.PrivateKey {
        let key = "remoteKeyboard.mac.signingPrivateKey"
        if let stored = UserDefaults.standard.string(forKey: key),
           let data = Data(base64Encoded: stored),
           let existing = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return existing
        }
        let created = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(created.rawRepresentation.base64EncodedString(), forKey: key)
        return created
    }

    private func publishClients() {
        let snapshot = clients.values.map { context in
            ClientSnapshot(id: context.id, deviceName: context.deviceName)
        }
        Task { @MainActor in
            self.onClientsChange?(snapshot)
        }
    }

    private func startFrameBroadcasting() {
        guard frameTimer == nil else { return }

        applyEffectiveQualityMode()
        adaptiveBitrateScale = 1.0
        adaptiveWindowTickCount = 0
        adaptiveWindowSkippedCount = 0
        adaptiveWindowEncodedCount = 0
        h264Encoder.setAdaptiveBitrateScale(adaptiveBitrateScale)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(120),
            repeating: .nanoseconds(Int(Self.frameIntervalNanos))
        )
        timer.setEventHandler { [weak self] in
            self?.broadcastScreenFrame()
        }
        timer.resume()
        frameTimer = timer
    }

    private func stopFrameBroadcasting() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    private func broadcastScreenFrame() {
        guard isSystemSleeping == false, isWakeRecoveryInProgress == false else {
            return
        }

        streamStatusHeartbeatTickCount += 1
        if streamStatusHeartbeatTickCount >= 60 {
            streamStatusHeartbeatTickCount = 0
            sendStreamStatusToAllPairedClients()
        }

        let pairedClientIDs = clients.compactMap { id, context in
            context.token == nil ? nil : id
        }

        guard pairedClientIDs.isEmpty == false else { return }
        adaptiveWindowTickCount += 1
        guard isFrameCaptureInFlight == false else {
            adaptiveWindowSkippedCount += 1
            updateAdaptiveBitrateIfNeeded()
            return
        }
        isFrameCaptureInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let framePixelBuffer = await self.screenCaptureProvider.makeFramePixelBuffer(maxWidth: self.previewCaptureMaxWidth)
            let cursorPosition = await self.screenCaptureProvider.normalizedCursorPosition()
            let snapshot = await self.screenCaptureProvider.currentCaptureSnapshot()
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isFrameCaptureInFlight = false
                self.applyCaptureSnapshot(snapshot)

                if let cursorPosition {
                    let cursorMessage = RemoteMessage.cursorPosition(
                        x: cursorPosition.x,
                        y: cursorPosition.y
                    )
                    for id in pairedClientIDs {
                        self.send(cursorMessage, to: id)
                    }
                }

                guard let framePixelBuffer else {
                    self.consecutiveFrameFailures += 1
                    self.publishCaptureActivityIfNeeded()
                    self.updateAdaptiveBitrateIfNeeded()
                    if self.consecutiveFrameFailures % 30 == 0 {
                        self.reportError("Screen preview capture failed repeatedly. Confirm Screen Recording permission for the Mac app.")
                    }
                    if self.consecutiveFrameFailures == 15 || self.consecutiveFrameFailures % 60 == 0 {
                        if self.isDisplaySleeping, self.clients.contains(where: { $0.value.token != nil }) {
                            self.sessionPower.wakeDisplaysNow()
                        }
                        self.syncHeadlessDisplay()
                    }
                    if self.consecutiveFrameFailures >= 60 {
                        self.recoverCapturePipelineIfNeeded(stateMessage: "Recovered capture after frame loss")
                    }
                    return
                }

                self.consecutiveFrameFailures = 0
                self.publishCaptureActivityIfNeeded()
                self.h264Encoder.encode(pixelBuffer: framePixelBuffer.value)
                self.adaptiveWindowEncodedCount += 1
                self.updateAdaptiveBitrateIfNeeded()
            }
        }
    }

    private func handleSystemWillSleep() {
        isSystemSleeping = true
        isDisplaySleeping = true
        isFrameCaptureInFlight = false
        consecutiveFrameFailures = 0
        publishCaptureActivityIfNeeded()
    }

    private func handleSystemDidWake() {
        guard isListenerRunning else { return }
        isSystemSleeping = false
        isDisplaySleeping = false
        sessionPower.invalidate()
        updateRemoteSessionPower()
        syncHeadlessDisplay()
        publishCaptureActivityIfNeeded()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after wake")
    }

    private func handleDisplaysDidSleep() {
        guard isListenerRunning else { return }
        isDisplaySleeping = true
        isFrameCaptureInFlight = false
        consecutiveFrameFailures = 0
        if clients.contains(where: { $0.value.token != nil }) {
            sessionPower.wakeDisplaysNow()
        }
        syncHeadlessDisplay()
        publishCaptureActivityIfNeeded()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display sleep")
    }

    private func handleDisplaysDidWake() {
        guard isListenerRunning else { return }
        isDisplaySleeping = false
        syncHeadlessDisplay()
        publishCaptureActivityIfNeeded()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display wake")
    }

    private func handleScreenParametersDidChange() {
        guard isListenerRunning, isSystemSleeping == false else { return }
        syncHeadlessDisplay()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display reconfiguration")
    }

    private func scheduleCaptureRecoveryBurst(stateMessage: String) {
        recoveryBurstGeneration &+= 1
        let generation = recoveryBurstGeneration
        let delays: [TimeInterval] = [0, 0.5, 1.0, 2.0, 4.0]

        for delay in delays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.recoveryBurstGeneration == generation else { return }
                self.recoverCapturePipelineIfNeeded(stateMessage: stateMessage)
            }
        }
    }

    private func recoverCapturePipelineIfNeeded(stateMessage: String) {
        guard isWakeRecoveryInProgress == false else { return }
        if let lastAttempt = lastCaptureRecoveryAttemptAt,
           Date().timeIntervalSince(lastAttempt) < 0.35 {
            return
        }

        isWakeRecoveryInProgress = true
        lastCaptureRecoveryAttemptAt = Date()

        let maxWidth = previewCaptureMaxWidth
        let virtualID = virtualDisplayManager.virtualDisplayID
        let preferred = preferredCaptureDisplayID
        let identity = preferredCaptureIdentity
        Task { [weak self] in
            guard let self else { return }
            await self.screenCaptureProvider.setSelectionPolicy(
                virtualDisplayID: virtualID,
                preferredDisplayID: preferred,
                preferredIdentity: identity
            )
            let recovered = await self.screenCaptureProvider.recoverAfterSystemWake(maxWidth: maxWidth)
            let snapshot = await self.screenCaptureProvider.currentCaptureSnapshot()
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isWakeRecoveryInProgress = false
                self.isFrameCaptureInFlight = false
                self.consecutiveFrameFailures = 0
                self.applyCaptureSnapshot(snapshot)
                self.publishCaptureActivityIfNeeded()

                if recovered {
                    self.h264Encoder.requestStreamResync()
                    self.aacEncoder.requestStreamResync()
                } else {
                    self.reportError("Capture recovery failed. Retrying automatically.")
                }
            }
        }
    }

    private func updateAdaptiveBitrateIfNeeded() {
        guard adaptiveWindowTickCount >= Self.adaptiveWindowTicks else { return }

        let skipRatio = Double(adaptiveWindowSkippedCount) / Double(adaptiveWindowTickCount)
        let encodedRatio = Double(adaptiveWindowEncodedCount) / Double(adaptiveWindowTickCount)

        var nextScale = adaptiveBitrateScale
        if consecutiveFrameFailures > 3 || skipRatio > 0.25 {
            nextScale -= 0.15
        } else if skipRatio > 0.12 {
            nextScale -= 0.08
        } else if skipRatio < 0.03, encodedRatio > 0.9, consecutiveFrameFailures == 0 {
            nextScale += 0.05
        }

        nextScale = min(max(nextScale, 0.45), 1.0)
        if abs(nextScale - adaptiveBitrateScale) > 0.01 {
            adaptiveBitrateScale = nextScale
            h264Encoder.setAdaptiveBitrateScale(adaptiveBitrateScale)
        }

        adaptiveWindowTickCount = 0
        adaptiveWindowSkippedCount = 0
        adaptiveWindowEncodedCount = 0
    }

    private func reportError(_ reason: String) {
        Task { @MainActor in
            self.onRuntimeError?(reason)
        }
    }

    private func publishCaptureRouteIfNeeded(_ label: String) {
        guard lastPublishedCaptureRouteLabel != label else { return }
        lastPublishedCaptureRouteLabel = label
        Task { @MainActor in
            self.onCaptureRouteChange?(label)
        }
        sendStreamStatusToAllPairedClients()
    }

    private func publishCaptureActivityIfNeeded() {
        let captureActive = currentPreviewCaptureActive()
        guard lastPublishedCaptureActive != captureActive else { return }
        lastPublishedCaptureActive = captureActive
        sendStreamStatusToAllPairedClients()
    }

    private func currentPreviewCaptureActive() -> Bool {
        isSystemSleeping == false && consecutiveFrameFailures < 15
    }

    private func currentHostDisplayCount() -> Int {
        virtualDisplayManager.physicalOnlineCount()
    }

    private func syncHeadlessDisplay() {
        guard isListenerRunning else { return }
        let result = virtualDisplayManager.syncWithPhysicalDisplays(enabled: virtualDisplayWhenHeadless)
        switch result {
        case .created(let displayID):
            let idLabel = displayID == 0 ? "pending" : String(displayID)
            Task { @MainActor in
                self.onStateChange?("Virtual display created (2560×1600) — no physical display online [ID \(idLabel)]")
            }
        case .creationFailed:
            Task { @MainActor in
                self.onStateChange?("Virtual display unavailable. If the monitor drops the HDMI link, an HDMI dummy plug is the hardware fallback.")
            }
        case .tornDown:
            Task { @MainActor in
                self.onStateChange?("Virtual display removed — physical display is online")
            }
        case .unchanged:
            break
        }
        pushCaptureSelectionPolicy()
        refreshDisplayCatalog()
    }

    private func pushCaptureSelectionPolicy() {
        let virtualID = virtualDisplayManager.virtualDisplayID
        let preferred = preferredCaptureDisplayID
        let identity = preferredCaptureIdentity
        Task { [weak self] in
            await self?.screenCaptureProvider.setSelectionPolicy(
                virtualDisplayID: virtualID,
                preferredDisplayID: preferred,
                preferredIdentity: identity
            )
        }
    }

    private func updateRemoteSessionPower() {
        guard isListenerRunning else {
            sessionPower.setRemoteSessionActive(false)
            return
        }
        let paired = clients.contains { $0.value.token != nil }
        sessionPower.setRemoteSessionActive(paired)
        if paired {
            sessionPower.wakeDisplaysNow()
        }
    }

    private func applyCaptureSnapshot(_ snapshot: CaptureTargetSnapshot?) {
        let label = snapshot?.summaryLabel ?? "No display"
        lastCaptureSummary = label
        if let snapshot {
            isDisplaySleeping = snapshot.isAsleep
            if snapshot.isAsleep, clients.contains(where: { $0.value.token != nil }) {
                let now = Date()
                if lastDisplayWakeAttemptAt == nil || now.timeIntervalSince(lastDisplayWakeAttemptAt ?? now) > 2 {
                    lastDisplayWakeAttemptAt = now
                    sessionPower.wakeDisplaysNow()
                }
            }
        }
        publishCaptureRouteIfNeeded(label)

        guard let snapshot else {
            if lastPointerDisplayID != 0 {
                lastPointerDisplayID = 0
                lastPointerBounds = .zero
                injector.setCapturedDisplayBounds(nil)
                publishDisplayCatalog()
            }
            return
        }

        let boundsChanged = snapshot.displayID != lastPointerDisplayID || snapshot.cgBounds.equalTo(lastPointerBounds) == false
        guard boundsChanged else { return }
        lastPointerDisplayID = snapshot.displayID
        lastPointerBounds = snapshot.cgBounds
        injector.setCapturedDisplayBounds(snapshot.cgBounds)
        injector.warpCursorIntoCapturedDisplayIfNeeded()
        publishDisplayCatalog()
    }

    private func refreshDisplayCatalog() {
        Task { @MainActor in
            let names = HostDisplayDirectory.localizedNames()
            self.queue.async { [weak self] in
                guard let self else { return }
                self.cachedDisplayNames = names
                self.publishDisplayCatalog()
            }
        }
    }

    private func publishDisplayCatalog() {
        let records = HostDisplayDirectory.onlineRecords(
            virtualDisplayID: virtualDisplayManager.virtualDisplayID,
            names: cachedDisplayNames,
            capturedID: lastPointerDisplayID == 0 ? nil : lastPointerDisplayID
        )
        cachedDisplayRecords = records
        reconcilePreferredDisplay(with: records)
        let snapshot = HostDisplayCatalogSnapshot(
            routeLabel: lastCaptureSummary,
            displays: cachedDisplayRecords.map(\.info),
            capturedDisplayID: lastPointerDisplayID,
            selectedDisplayID: preferredCaptureDisplayID,
            virtualDisplayWhenHeadless: virtualDisplayWhenHeadless
        )
        Task { @MainActor in
            self.onDisplayCatalogChange?(snapshot)
        }
        sendStreamStatusToAllPairedClients()
    }

    private func reconcilePreferredDisplay(with records: [HostDisplayRecord]) {
        guard preferredCaptureDisplayID != 0 else { return }
        if records.contains(where: { $0.info.id == preferredCaptureDisplayID }) { return }
        guard let identity = preferredCaptureIdentity, identity.isSpecific else { return }
        let matches = records.filter { $0.identity == identity }
        guard matches.count == 1, let match = matches.first else { return }
        preferredCaptureDisplayID = match.info.id
        HostDisplayPreferences.saveSelection(displayID: match.info.id, identity: identity)
        pushCaptureSelectionPolicy()
    }

    private func handleThermalStateChange(_ state: ProcessInfo.ThermalState) {
        guard thermalState != state else { return }
        thermalState = state

        switch state {
        case .serious, .critical:
            isThermalOverrideActive = true
            Task { @MainActor in
                self.onStateChange?("Thermal pressure high. Auto-switched preview to Balanced.")
            }
        case .nominal, .fair:
            isThermalOverrideActive = false
            Task { @MainActor in
                self.onStateChange?("Thermal pressure recovered. Restoring selected preview quality.")
            }
        @unknown default:
            break
        }

        applyEffectiveQualityMode()
        sendStreamStatusToAllPairedClients()
    }

    private func applyEffectiveQualityMode() {
        let nextMode: PreviewQualityMode = isThermalOverrideActive ? .balanced : userSelectedQualityMode
        guard effectiveQualityMode != nextMode else { return }
        effectiveQualityMode = nextMode

        switch nextMode {
        case .balanced:
            if requestedPreviewZoomLevel >= 2.5 {
                previewCaptureMaxWidth = 1680
            } else {
                previewCaptureMaxWidth = 1440
            }
            h264Encoder.setQualityProfile(.balanced)
        case .ultra:
            if requestedPreviewZoomLevel >= 2.5 {
                previewCaptureMaxWidth = 2560
                h264Encoder.setQualityProfile(.ultraZoom)
            } else if requestedPreviewZoomLevel >= 1.5 {
                previewCaptureMaxWidth = 2240
                h264Encoder.setQualityProfile(.ultra)
            } else {
                previewCaptureMaxWidth = 1920
                h264Encoder.setQualityProfile(.ultra)
            }
        }
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CapturedAudioSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.selectedAudioCaptureSource != .off else { return }
            let hasPairedClients = self.clients.contains { _, context in
                context.token != nil
            }
            guard hasPairedClients else { return }
            self.aacEncoder.encode(sampleBuffer: sampleBuffer.value)
        }
    }

    private func currentHostPermissionStatus() -> (accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        let accessibilityGranted = accessibilityPermissionManager.isTrusted()
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        return (accessibilityGranted, screenRecordingGranted)
    }

    private func assertHostPermissionsForControl(to id: UUID) -> Bool {
        let status = currentHostPermissionStatus()
        guard status.accessibilityGranted, status.screenRecordingGranted else {
            send(.error("Host permissions are required before remote control can start."), to: id)
            sendPermissionStatus(to: id)
            return false
        }
        return true
    }

    private func sendPermissionStatus(to id: UUID) {
        let status = currentHostPermissionStatus()
        send(
            .permissionStatus(
                accessibilityGranted: status.accessibilityGranted,
                screenRecordingGranted: status.screenRecordingGranted
            ),
            to: id
        )
    }

    private func openSystemSettings(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }

    private func sendStreamStatus(to id: UUID) {
        send(
            .streamStatus(
                thermalOverrideActive: isThermalOverrideActive,
                captureRoute: lastPublishedCaptureRouteLabel,
                hostDisplayCount: currentHostDisplayCount(),
                previewCaptureActive: currentPreviewCaptureActive(),
                displays: cachedDisplayRecords.map(\.info),
                capturedDisplayID: lastPointerDisplayID == 0 ? nil : lastPointerDisplayID,
                capturedDisplayName: lastCaptureSummary,
                selectedDisplayID: preferredCaptureDisplayID,
                virtualDisplayWhenHeadless: virtualDisplayWhenHeadless
            ),
            to: id
        )
    }

    private func sendStreamStatusToAllPairedClients() {
        let pairedClientIDs = clients.compactMap { id, context in
            context.token == nil ? nil : id
        }
        for id in pairedClientIDs {
            sendStreamStatus(to: id)
        }
    }
}
