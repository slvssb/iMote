import AppKit
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

    var onStateChange: ((String) -> Void)?
    var onClientsChange: (([ClientSnapshot]) -> Void)?
    var onRuntimeError: ((String) -> Void)?

    private struct ClientContext {
        let id: UUID
        let connection: NWConnection
        var token: String?
        var deviceName: String?
    }

    private let pairingManager: PairingManager
    private let injector: KeyboardInjector
    private let screenCaptureProvider = MacScreenCaptureProvider()
    private let h264Encoder = H264FrameEncoder()
    private let queue = DispatchQueue(label: "remote.keyboard.mac.ws")

    private var listener: NWListener?
    private var clients: [UUID: ClientContext] = [:]
    private var frameTimer: DispatchSourceTimer?
    private var isFrameCaptureInFlight = false
    private var consecutiveFrameFailures = 0
    private var previewQualityMode: PreviewQualityMode = .ultra
    private var previewBaseCaptureMaxWidth: CGFloat = 1920
    private var previewCaptureMaxWidth: CGFloat = 1920
    private var pointerProfile: PointerProfile = .edgeAssist
    private var adaptiveBitrateScale: Double = 1.0
    private var adaptiveResolutionLevels: [CGFloat] = [1.0, 0.85, 0.7, 0.58]
    private var adaptiveResolutionIndex = 0
    private var adaptiveWindowTickCount = 0
    private var adaptiveWindowSkippedCount = 0
    private var adaptiveWindowEncodedCount = 0
    private var lastAdaptiveSkipRatio: Double = 0
    private var telemetryTickCount = 0

    init(pairingManager: PairingManager, injector: KeyboardInjector) {
        self.pairingManager = pairingManager
        self.injector = injector

        h264Encoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.queue.async {
                let pairedClientIDs = self.clients.compactMap { id, context in
                    context.token == nil ? nil : id
                }
                for id in pairedClientIDs {
                    self.sendBinaryFrame(packet, to: id)
                }
            }
        }
    }

    func start(port: UInt16 = 8989) throws {
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
        wsListener.start(queue: queue)
        startFrameBroadcasting()
    }

    func stop() {
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
            self.publishClients()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let context = ClientContext(id: id, connection: connection, token: nil, deviceName: nil)
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

            if let data, data.isEmpty == false {
                self.handlePayload(data, from: id)
            }

            self.receiveNext(for: id)
        }
    }

    private func handlePayload(_ data: Data, from id: UUID) {
        guard let message = try? RemoteProtocolCodec.decode(data) else {
            send(.error("Malformed JSON payload"), to: id)
            return
        }

        switch message.type {
        case .pair:
            handlePair(message, from: id)
        case .text:
            handleText(message, from: id)
        case .key:
            handleKey(message, from: id)
        case .mouseMove:
            handleMouseMove(message, from: id)
        case .mouseClick:
            handleMouseClick(message, from: id)
        case .mouseScroll:
            handleMouseScroll(message, from: id)
        case .streamConfig:
            handleStreamConfig(message, from: id)
        case .ping:
            send(RemoteMessage(type: .pong), to: id)
        default:
            break
        }
    }

    private func handlePair(_ message: RemoteMessage, from id: UUID) {
        let submitted = message.code ?? ""
        let result = pairingManager.pair(code: submitted, deviceID: message.deviceID)
        guard var context = clients[id] else { return }
        if result.success, let token = result.token {
            context.token = token
            context.deviceName = message.deviceName
            clients[id] = context
            send(.pairAck(success: true, token: token, reason: nil), to: id)
            publishClients()
        } else {
            send(.pairAck(success: false, token: nil, reason: result.reason), to: id)
        }
    }

    private func handleText(_ message: RemoteMessage, from id: UUID) {
        let isAuthorized = authorize(id: id, token: message.token)
        guard isAuthorized else {
            send(.error("Unauthorized session token"), to: id)
            return
        }
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

        let deltaX = message.deltaX ?? 0
        let deltaY = message.deltaY ?? 0
        guard deltaX != 0 || deltaY != 0 else { return }

        do {
            try injector.injectMouseMove(deltaX: deltaX, deltaY: deltaY)
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

        let action = message.action ?? .tap
        let button = message.button ?? .left

        do {
            try injector.injectMouseClick(button: button, action: action)
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

        let scrollX = message.scrollX ?? 0
        let scrollY = message.scrollY ?? 0
        guard scrollX != 0 || scrollY != 0 else { return }

        do {
            try injector.injectMouseScroll(scrollX: scrollX, scrollY: scrollY)
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

        if let mode = message.qualityMode {
            previewQualityMode = mode

            switch mode {
            case .balanced:
                previewBaseCaptureMaxWidth = 1440
                h264Encoder.setQualityProfile(.balanced)
            case .ultra:
                previewBaseCaptureMaxWidth = 1920
                h264Encoder.setQualityProfile(.ultra)
            }

            adaptiveResolutionIndex = 0
            updateCaptureWidthFromAdaptiveResolution()
        }

        if let profile = message.pointerProfile {
            pointerProfile = profile
            injector.setPointerProfile(profile)
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

    private func send(_ message: RemoteMessage, to id: UUID) {
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
        context.connection.send(
            content: payload,
            contentContext: contentContext,
            isComplete: true,
            completion: .idempotent
        )
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

        adaptiveBitrateScale = 1.0
        adaptiveResolutionIndex = 0
        adaptiveWindowTickCount = 0
        adaptiveWindowSkippedCount = 0
        adaptiveWindowEncodedCount = 0
        lastAdaptiveSkipRatio = 0
        telemetryTickCount = 0
        injector.setPointerProfile(pointerProfile)
        updateCaptureWidthFromAdaptiveResolution()
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
        let pairedClientIDs = clients.compactMap { id, context in
            context.token == nil ? nil : id
        }

        guard pairedClientIDs.isEmpty == false else { return }
        adaptiveWindowTickCount += 1
        telemetryTickCount += 1
        guard isFrameCaptureInFlight == false else {
            adaptiveWindowSkippedCount += 1
            updateAdaptiveBitrateIfNeeded()
            sendTelemetryIfNeeded(to: pairedClientIDs)
            return
        }
        isFrameCaptureInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let framePixelBuffer = await self.screenCaptureProvider.makeFramePixelBuffer(maxWidth: self.previewCaptureMaxWidth)
            let cursorPosition = await self.screenCaptureProvider.normalizedCursorPosition()
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isFrameCaptureInFlight = false

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
                    self.updateAdaptiveBitrateIfNeeded()
                    if self.consecutiveFrameFailures % 30 == 0 {
                        self.reportError("Screen preview capture failed repeatedly. Confirm Screen Recording permission for the Mac app.")
                    }
                    self.sendTelemetryIfNeeded(to: pairedClientIDs)
                    return
                }

                self.consecutiveFrameFailures = 0
                self.h264Encoder.encode(pixelBuffer: framePixelBuffer.value)
                self.adaptiveWindowEncodedCount += 1
                self.updateAdaptiveBitrateIfNeeded()
                self.sendTelemetryIfNeeded(to: pairedClientIDs)
            }
        }
    }

    private func updateAdaptiveBitrateIfNeeded() {
        guard adaptiveWindowTickCount >= Self.adaptiveWindowTicks else { return }

        let skipRatio = Double(adaptiveWindowSkippedCount) / Double(adaptiveWindowTickCount)
        let encodedRatio = Double(adaptiveWindowEncodedCount) / Double(adaptiveWindowTickCount)
        lastAdaptiveSkipRatio = skipRatio

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

        if consecutiveFrameFailures > 3 || skipRatio > 0.25 {
            adaptiveResolutionIndex = min(adaptiveResolutionIndex + 1, adaptiveResolutionLevels.count - 1)
        } else if skipRatio < 0.04, encodedRatio > 0.9, consecutiveFrameFailures == 0 {
            adaptiveResolutionIndex = max(adaptiveResolutionIndex - 1, 0)
        }
        updateCaptureWidthFromAdaptiveResolution()

        adaptiveWindowTickCount = 0
        adaptiveWindowSkippedCount = 0
        adaptiveWindowEncodedCount = 0
    }

    private func updateCaptureWidthFromAdaptiveResolution() {
        let scale = adaptiveResolutionLevels[adaptiveResolutionIndex]
        previewCaptureMaxWidth = max(960, previewBaseCaptureMaxWidth * scale)
    }

    private func sendTelemetryIfNeeded(to clientIDs: [UUID]) {
        guard telemetryTickCount >= 60 else { return }
        telemetryTickCount = 0

        let telemetry = RemoteMessage.telemetry(
            serverFPS: 60,
            captureWidth: Double(previewCaptureMaxWidth),
            captureHeight: Double(previewCaptureMaxWidth / (16.0 / 10.0)),
            adaptiveBitrateScale: adaptiveBitrateScale,
            skipRatio: lastAdaptiveSkipRatio
        )

        for id in clientIDs {
            send(telemetry, to: id)
        }
    }

    private func reportError(_ reason: String) {
        Task { @MainActor in
            self.onRuntimeError?(reason)
        }
    }
}
