import AppKit
import CryptoKit
import CoreGraphics
import Foundation
import Network

final class MacWebSocketServer: @unchecked Sendable {
    private static let frameIntervalNanos: UInt64 = 16_666_667
    private static let adaptiveWindowTicks = 60
    private static let maxClients = 8
    private static let maxUnauthenticatedClients = 4
    private static let maximumMessageBytes = 8 * 1024 * 1024

    struct ClientSnapshot: Sendable {
        let id: UUID
        let deviceName: String?
        let isPaired: Bool
    }

    struct MediaStatus: Equatable, Sendable {
        var selectedQuality: PreviewQualityMode
        var effectiveQuality: PreviewQualityMode
        var audioSource: AudioCaptureSource
        var thermalOverrideActive: Bool
    }

    var onStateChange: ((String) -> Void)?
    var onClientsChange: (([ClientSnapshot]) -> Void)?
    var onRuntimeError: ((String) -> Void)?
    var onCaptureRouteChange: ((String) -> Void)?
    var onMediaStatusChange: ((MediaStatus) -> Void)?
    var onIdentityPinned: ((String, Bool) -> Void)?

    private struct ClientContext {
        let id: UUID
        let connection: NWConnection
        var token: String?
        var deviceName: String?
        var secureSession: SecureSession?
        var outstandingBytes: Int = 0
    }

    private struct SecureSession {
        let clientDeviceID: String
        let controlKey: SymmetricKey
        let mediaKey: SymmetricKey
        var clientToHostControlCounter: UInt64 = 0
        var hostToClientControlCounter: UInt64 = 0
        var hostToClientMediaCounter: UInt64 = 0
    }

    private let pairingManager: PairingManager
    private let injector: KeyboardInjector
    private let accessibilityPermissionManager: AccessibilityPermissionManager
    private let screenCaptureProvider = MacScreenCaptureProvider()
    private let h264Encoder = H264FrameEncoder()
    private let aacEncoder = AACAudioEncoder()
    private let virtualDisplayManager = VirtualDisplayManager()
    private let queue = DispatchQueue(label: "remote.keyboard.mac.ws")
    private let queueSpecificKey = DispatchSpecificKey<Void>()
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
    private var appliedPreviewZoomLevel: Double = -1
    private var selectedAudioCaptureSource: AudioCaptureSource = .off
    private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var isThermalOverrideActive = false
    private var previewCaptureMaxWidth: CGFloat = 1920
    private var adaptiveBitrateScale: Double = 1.0
    private var sendPressureScale: Double = 1.0
    private var videoPressureLatched = false
    private let videoDropOutstandingBytes = 750_000
    private var adaptiveWindowTickCount = 0
    private var adaptiveWindowSkippedCount = 0
    private var adaptiveWindowEncodedCount = 0
    private var streamStatusHeartbeatTickCount = 0
    private var audioDebugSentConfigCount = 0
    private var audioDebugSentFrameCount = 0
    private let localSigningPrivateKey: Curve25519.Signing.PrivateKey
    private let hostDeviceID = MacWebSocketServer.loadOrCreateHostDeviceID()
    private var isSystemSleeping = false
    private var isDisplaySleeping = false
    private var isWakeRecoveryInProgress = false
    private var lastCaptureRecoveryAttemptAt: Date?
    private var recoveryBurstGeneration: UInt64 = 0
    private var lastPublishedCaptureRouteLabel: String = "Unknown"
    private var lastPublishedCaptureActive: Bool?

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
        queue.setSpecific(key: queueSpecificKey, value: ())
        let identity = SigningIdentityStore.loadOrCreate(
            account: "host-signing",
            legacyDefaultsKey: "remoteKeyboard.mac.signingPrivateKey"
        )
        self.localSigningPrivateKey = identity.key
        if identity.didDiscardLegacyKey {
            pairingManager.clearTrustedDevices()
        }

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
        try onQueue {
            try self.startOnQueue(port: port)
        }
    }

    private func startOnQueue(port: UInt16) throws {
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
        wsOptions.maximumMessageSize = Self.maximumMessageBytes
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        // Wildcard bind. Leaving requiredInterface unset accepts Wi-Fi, Ethernet,
        // and Tailscale's utun interface. Bonjour advertisement stays local-only.
        parameters.acceptLocalOnly = false

        let wsListener = try NWListener(using: parameters, on: listenPort)
        wsListener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac Keyboard", type: "_rkbd._tcp")

        wsListener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
            guard let self else { return }
            let description: String
            switch state {
            case .ready:
                description = "Listening on port \(port) (all interfaces)"
                self.publishMediaStatus()
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
        wsListener.start(queue: queue)
        applyVirtualDisplayIfNeeded()
        startFrameBroadcasting()
    }

    func stop() {
        onQueue {
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        clients.values.forEach { context in
            context.connection.cancel()
        }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        stopFrameBroadcasting()
        suspendCaptureBecauseNoPhonesRemain()
        h264Encoder.stop()
        aacEncoder.stop()
        virtualDisplayManager.tearDown()
        publishClients()
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private func accept(_ connection: NWConnection) {
        let unauthenticated = clients.values.filter { $0.token == nil }.count
        if clients.count >= Self.maxClients || unauthenticated >= Self.maxUnauthenticatedClients {
            connection.cancel()
            reportError("Rejected a connection because too many clients are already connected.")
            return
        }

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
        injector.releasePressedMouseButtons(for: id)
        if let removed = clients.removeValue(forKey: id) {
            pairingManager.revoke(token: removed.token)
        }
        publishClients()
        refreshCaptureForConnectedPhones()
    }

    private func refreshCaptureForConnectedPhones() {
        let hasPairedPhone = clients.values.contains { $0.token != nil }
        if hasPairedPhone {
            Task { [weak self] in
                await self?.screenCaptureProvider.resumeCaptureForPairedClient()
            }
        } else {
            suspendCaptureBecauseNoPhonesRemain()
        }
    }

    private func suspendCaptureBecauseNoPhonesRemain() {
        selectedAudioCaptureSource = .off
        h264Encoder.stop()
        aacEncoder.stop()
        publishMediaStatus()
        Task { [weak self] in
            await self?.screenCaptureProvider.suspendForIdleClients()
        }
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
        case .ping:
            if clients[id]?.secureSession != nil, isFromSecureChannel == false {
                return
            }
            send(RemoteMessage(type: .pong), to: id)
        default:
            break
        }
    }

    private func handleSecureControl(_ message: RemoteMessage, from id: UUID) {
        guard var context = clients[id], var secureSession = context.secureSession else {
            send(.error("Unauthorized secure control session"), to: id)
            return
        }
        guard let payloadBase64 = message.securePayload,
              let combined = Data(base64Encoded: payloadBase64) else {
            failSecureChannel(id: id, reason: RemoteProtocol.secureChannelFailedReason)
            return
        }

        do {
            let plaintext = try SecureChannelCodec.open(
                combined: combined,
                using: secureSession.controlKey,
                kind: .control,
                direction: .clientToHost,
                counter: secureSession.clientToHostControlCounter
            )
            secureSession.clientToHostControlCounter += 1
            context.secureSession = secureSession
            clients[id] = context
            let inner = try RemoteProtocolCodec.decode(plaintext)
            guard inner.type != .secureControl else {
                send(.error("Nested secure control payload is not allowed"), to: id)
                return
            }
            handleDecodedMessage(inner, from: id, isFromSecureChannel: true)
        } catch {
            failSecureChannel(id: id, reason: RemoteProtocol.secureChannelFailedReason)
        }
    }

    private func failSecureChannel(id: UUID, reason: String) {
        guard let context = clients[id] else { return }
        var cleared = context
        cleared.secureSession = nil
        clients[id] = cleared
        send(.error(reason), to: id)
        context.connection.cancel()
        disconnect(id: id)
    }

    private func handlePair(_ message: RemoteMessage, from id: UUID) {
        guard message.protocolVersion == RemoteProtocol.version else {
            send(.pairAck(success: false, token: nil, reason: RemoteProtocol.incompatibleClientReason), to: id)
            return
        }

        let submitted = message.code ?? ""
        let result = pairingManager.pair(code: submitted, deviceID: message.deviceID)
        guard var context = clients[id] else { return }
        if result.success, let token = result.token {
            context.token = token
            context.deviceName = message.deviceName
            context.secureSession = nil
            clients[id] = context
            send(.pairAck(success: true, token: token, reason: nil), to: id, deviceIDOverride: hostDeviceID)
            sendStreamStatus(to: id)
            sendPermissionStatus(to: id)
            publishClients()
            refreshCaptureForConnectedPhones()
        } else {
            send(.pairAck(success: false, token: nil, reason: result.reason), to: id)
        }
    }

    private func handleE2EHello(_ message: RemoteMessage, from id: UUID) {
        guard message.protocolVersion == RemoteProtocol.version else {
            send(.error(RemoteProtocol.incompatibleClientReason), to: id)
            return
        }
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

        if let boundDeviceID = pairingManager.provisionalDeviceID(for: token), boundDeviceID != clientDeviceID {
            send(.error("Handshake device does not match the paired device."), to: id)
            return
        }

        let clientSigningKey: Curve25519.Signing.PublicKey
        do {
            clientSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: clientSigningKeyData)
        } catch {
            send(.error("Malformed secure handshake payload"), to: id)
            return
        }
        let signaturePayload = Self.signaturePayload(token: token, deviceID: clientDeviceID, ephemeralPublicKey: clientEphemeralData)
        guard clientSigningKey.isValidSignature(signatureData, for: signaturePayload) else {
            send(.error("Invalid secure handshake signature"), to: id)
            return
        }

        let pin = pairingManager.pinSigningKeyAfterVerification(
            deviceID: clientDeviceID,
            signingPublicKeyBase64: clientSigningKeyBase64
        )
        guard pin != .mismatch else {
            send(.error("Client identity key mismatch. Clear trusted devices on the Mac and pair again."), to: id)
            return
        }

        var didConfirmTrust = false
        do {
            let hostEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            let hostEphemeralPublicData = hostEphemeralPrivateKey.publicKey.rawRepresentation
            let clientEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientEphemeralData)
            let sharedSecret = try hostEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: clientEphemeralPublicKey)
            let salt = Data(token.utf8)
            let controlKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("iMote.e2e.control.v2".utf8),
                outputByteCount: 32
            )
            let mediaKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("iMote.e2e.media.v2".utf8),
                outputByteCount: 32
            )

            guard pairingManager.confirmTrustedDeviceAfterHandshake(token: token, deviceID: clientDeviceID) else {
                if pin == .pinnedNew {
                    pairingManager.rollbackNewSigningPin(deviceID: clientDeviceID)
                }
                send(.error("Handshake device does not match the paired device."), to: id)
                return
            }
            didConfirmTrust = true
            if let deviceName = clients[id]?.deviceName {
                pairingManager.noteTrustedDevice(deviceID: clientDeviceID, name: deviceName)
            }

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
            let fingerprint = IdentityFingerprint.displayString(forPublicKey: clientSigningKeyData)
            let isNewPin = pin == .pinnedNew
            Task { @MainActor in
                self.onIdentityPinned?(fingerprint, isNewPin)
            }
        } catch {
            if didConfirmTrust == false, pin == .pinnedNew {
                pairingManager.rollbackNewSigningPin(deviceID: clientDeviceID)
            }
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
            try injector.injectMouseClick(button: button, modifiers: modifiers, action: action, clientID: id)
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
        publishMediaStatus()
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
        publishMediaStatus()
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
        if shouldProtect(message, clientID: id) {
            sendEncryptedControl(message, to: id)
            return
        }
        guard let payload = try? RemoteProtocolCodec.encode(message) else {
            return
        }
        sendBinaryFrame(payload, to: id)
    }

    private func shouldProtect(_ message: RemoteMessage, clientID: UUID) -> Bool {
        guard clients[clientID]?.secureSession != nil else { return false }
        switch message.type {
        case .pair, .pairAck, .e2eHello, .e2eHelloAck:
            return false
        default:
            return true
        }
    }

    private func sendEncryptedControl(_ message: RemoteMessage, to id: UUID) {
        guard var context = clients[id], var session = context.secureSession else { return }
        do {
            let plaintext = try RemoteProtocolCodec.encode(message)
            let combined = try SecureChannelCodec.seal(
                plaintext,
                using: session.controlKey,
                kind: .control,
                direction: .hostToClient,
                counter: session.hostToClientControlCounter
            )
            session.hostToClientControlCounter += 1
            context.secureSession = session
            clients[id] = context
            let outer = RemoteMessage.secureControl(payloadBase64: combined.base64EncodedString())
            guard let payload = try? RemoteProtocolCodec.encode(outer) else { return }
            sendBinaryFrame(payload, to: id)
        } catch {
            failSecureChannel(id: id, reason: RemoteProtocol.secureChannelFailedReason)
        }
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
        if Self.isDroppableVideoFrame(payload), context.outstandingBytes > videoDropOutstandingBytes {
            noteVideoSendPressure()
            return
        }

        let outboundPayload: Data
        if var session = context.secureSession, Self.isMediaPacket(payload) {
            do {
                let combined = try SecureChannelCodec.seal(
                    payload,
                    using: session.mediaKey,
                    kind: .media,
                    direction: .hostToClient,
                    counter: session.hostToClientMediaCounter
                )
                session.hostToClientMediaCounter += 1
                var updated = context
                updated.secureSession = session
                clients[id] = updated
                var packet = Data([BinaryPacketMarker.encryptedMedia])
                packet.append(combined)
                outboundPayload = packet
            } catch {
                failSecureChannel(id: id, reason: RemoteProtocol.secureChannelFailedReason)
                return
            }
        } else {
            outboundPayload = payload
        }

        let byteCount = outboundPayload.count
        if var current = clients[id] {
            current.outstandingBytes += byteCount
            clients[id] = current
        }
        context.connection.send(
            content: outboundPayload,
            contentContext: contentContext,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.queue.async {
                    guard var current = self?.clients[id] else { return }
                    current.outstandingBytes = max(0, current.outstandingBytes - byteCount)
                    self?.clients[id] = current
                    self?.refreshBitrateFromSendPressure()
                }
            }
        )
    }

    private func noteVideoSendPressure() {
        videoPressureLatched = true
        refreshBitrateFromSendPressure()
    }

    private func refreshBitrateFromSendPressure() {
        let pending = clients.values.map(\.outstandingBytes).max() ?? 0
        if pending > videoDropOutstandingBytes {
            videoPressureLatched = true
        } else if videoPressureLatched, pending < 200_000 {
            videoPressureLatched = false
            h264Encoder.requestStreamResync()
        }

        var next = sendPressureScale
        if pending > 2_000_000 {
            next -= 0.12
        } else if pending > videoDropOutstandingBytes {
            next -= 0.06
        } else if pending < 180_000 {
            next += 0.04
        }
        next = min(max(next, 0.35), 1.0)
        guard abs(next - sendPressureScale) > 0.02 else { return }
        sendPressureScale = next
        h264Encoder.setAdaptiveBitrateScale(min(adaptiveBitrateScale, sendPressureScale))
    }

    private static func isDroppableVideoFrame(_ payload: Data) -> Bool {
        guard payload.first == BinaryPacketMarker.h264Frame, payload.count > 5 else { return false }
        var offset = 1
        var sawKeyframe = false
        while offset + 4 < payload.count {
            let length = (Int(payload[offset]) << 24)
                | (Int(payload[offset + 1]) << 16)
                | (Int(payload[offset + 2]) << 8)
                | Int(payload[offset + 3])
            let nalIndex = offset + 4
            guard length > 0, nalIndex < payload.count else { return false }
            let nalType = payload[nalIndex] & 0x1F
            if nalType == 5 {
                sawKeyframe = true
            }
            let next = nalIndex + length
            guard next > offset else { return false }
            offset = next
        }
        return sawKeyframe == false
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
        payload.append(contentsOf: Data("iMote.e2e.handshake.v2|".utf8))
        payload.append(contentsOf: Data(token.utf8))
        payload.append(contentsOf: Data("|".utf8))
        payload.append(contentsOf: Data(deviceID.utf8))
        payload.append(contentsOf: Data("|".utf8))
        payload.append(ephemeralPublicKey)
        return payload
    }

    var localSigningFingerprint: String {
        IdentityFingerprint.displayString(forPublicKey: localSigningPrivateKey.publicKey.rawRepresentation)
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


    private func publishClients() {
        let snapshot = clients.values.map { context in
            ClientSnapshot(id: context.id, deviceName: context.deviceName, isPaired: context.token != nil)
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
        guard h264Encoder.canAcceptFrame() else {
            adaptiveWindowTickCount += 1
            adaptiveWindowSkippedCount += 1
            updateAdaptiveBitrateIfNeeded()
            return
        }
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
            let captureRouteLabel = await self.screenCaptureProvider.currentCaptureRouteLabel()
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isFrameCaptureInFlight = false
                let effectiveRouteLabel = self.virtualDisplayManager.isActive ? "Virtual" : captureRouteLabel
                self.publishCaptureRouteIfNeeded(effectiveRouteLabel)

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
                    if self.consecutiveFrameFailures >= 60 {
                        self.recoverCapturePipelineIfNeeded(stateMessage: "Recovered capture after frame loss")
                    }
                    return
                }

                self.consecutiveFrameFailures = 0
                self.publishCaptureActivityIfNeeded()
                if self.h264Encoder.encode(pixelBuffer: framePixelBuffer.value) {
                    self.adaptiveWindowEncodedCount += 1
                } else {
                    self.adaptiveWindowSkippedCount += 1
                }
                self.updateAdaptiveBitrateIfNeeded()
            }
        }
    }

    private func handleSystemWillSleep() {
        isSystemSleeping = true
        isDisplaySleeping = true
        Task { [weak self] in
            await self?.screenCaptureProvider.setPreferFallbackDisplay(true)
        }
        isFrameCaptureInFlight = false
        consecutiveFrameFailures = 0
        publishCaptureActivityIfNeeded()
    }

    private func handleSystemDidWake() {
        isSystemSleeping = false
        isDisplaySleeping = false
        Task { [weak self] in
            await self?.screenCaptureProvider.setPreferFallbackDisplay(false)
        }
        applyVirtualDisplayIfNeeded()
        publishCaptureActivityIfNeeded()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after wake")
    }

    private func handleDisplaysDidSleep() {
        isDisplaySleeping = true
        Task { [weak self] in
            await self?.screenCaptureProvider.setPreferFallbackDisplay(true)
        }
        isFrameCaptureInFlight = false
        consecutiveFrameFailures = 0
        publishCaptureActivityIfNeeded()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display sleep")
    }

    private func handleDisplaysDidWake() {
        isDisplaySleeping = false
        Task { [weak self] in
            await self?.screenCaptureProvider.setPreferFallbackDisplay(false)
        }
        publishCaptureActivityIfNeeded()
        scheduleCaptureRecoveryBurst(stateMessage: "Recovered capture after display wake")
    }

    private func handleScreenParametersDidChange() {
        guard isSystemSleeping == false else { return }
        applyVirtualDisplayIfNeeded()
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
        Task { [weak self] in
            guard let self else { return }
            let recovered = await self.screenCaptureProvider.recoverAfterSystemWake(maxWidth: maxWidth)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isWakeRecoveryInProgress = false
                self.isFrameCaptureInFlight = false
                self.consecutiveFrameFailures = 0
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
            h264Encoder.setAdaptiveBitrateScale(min(adaptiveBitrateScale, sendPressureScale))
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
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(maxDisplays, &displays, &count)
        guard result == .success else { return 0 }
        return Int(count)
    }

    private func applyVirtualDisplayIfNeeded() {
        guard let event = virtualDisplayManager.ensureDisplayAvailable() else { return }
        switch event {
        case .created:
            let displayID = virtualDisplayManager.virtualDisplayID.map { String($0) } ?? "?"
            Task { @MainActor in
                self.onStateChange?("Virtual display created (2560×1600) — headless mode [ID \(displayID)]")
            }
        case .creationFailed:
            Task { @MainActor in
                self.onStateChange?("Virtual display creation failed — headless capture unavailable")
            }
        case .tornDown:
            Task { @MainActor in
                self.onStateChange?("Virtual display removed — physical display detected")
            }
        }
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
        publishMediaStatus()
        sendStreamStatusToAllPairedClients()
    }

    private func applyEffectiveQualityMode() {
        let nextMode: PreviewQualityMode = isThermalOverrideActive ? .balanced : userSelectedQualityMode
        let zoom = requestedPreviewZoomLevel
        let nextWidth: CGFloat
        let nextProfile: H264FrameEncoder.QualityProfile
        switch nextMode {
        case .balanced:
            nextWidth = zoom >= 2.5 ? 1680 : 1440
            nextProfile = .balanced
        case .ultra:
            if zoom >= 2.5 {
                nextWidth = 2560
                nextProfile = .ultraZoom
            } else if zoom >= 1.5 {
                nextWidth = 2240
                nextProfile = .ultra
            } else {
                nextWidth = 1920
                nextProfile = .ultra
            }
        }

        let modeChanged = effectiveQualityMode != nextMode
        let zoomChanged = abs(appliedPreviewZoomLevel - zoom) > 0.01
        let widthChanged = abs(previewCaptureMaxWidth - nextWidth) > 0.5
        guard modeChanged || zoomChanged || widthChanged else { return }

        effectiveQualityMode = nextMode
        appliedPreviewZoomLevel = zoom
        previewCaptureMaxWidth = nextWidth
        h264Encoder.setQualityProfile(nextProfile)
        publishMediaStatus()
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

    private func publishMediaStatus() {
        let status = MediaStatus(
            selectedQuality: userSelectedQualityMode,
            effectiveQuality: effectiveQualityMode,
            audioSource: selectedAudioCaptureSource,
            thermalOverrideActive: isThermalOverrideActive
        )
        Task { @MainActor in
            self.onMediaStatusChange?(status)
        }
    }

    private func currentHostPermissionStatus() -> (accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        let accessibilityGranted = accessibilityPermissionManager.isTrusted()
        let screenRecordingGranted = CGPreflightScreenCaptureAccess()
        return (accessibilityGranted, screenRecordingGranted)
    }

    private func assertHostPermissionsForControl(to id: UUID) -> Bool {
        let status = currentHostPermissionStatus()
        guard status.accessibilityGranted else {
            send(.error("Accessibility permission is required before remote control can start."), to: id)
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
                previewCaptureActive: currentPreviewCaptureActive()
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
