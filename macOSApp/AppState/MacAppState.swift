import AppKit
import Combine
import CoreGraphics
import Foundation
import Network
import ServiceManagement

struct ConnectedPhone: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isPaired: Bool
}

enum HostPrivacyPane {
    case accessibility
    case screenRecording
}

@MainActor
final class MacAppState: ObservableObject {
    @Published var serverStatus = "Stopped"
    @Published var connectedPhones: [ConnectedPhone] = []
    @Published var pairingCode = "------"
    @Published var pairingSecondsRemaining = 0
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var trustedDevices: [TrustedDeviceRecord] = []
    @Published var lastError: String?
    @Published var startOnLoginEnabled = false
    @Published var captureRouteStatus = "Unknown"
    @Published var listenerPort: UInt16 = 8989
    @Published var isListenerRunning = false
    @Published var endpointSnapshot = HostEndpointCatalog.Snapshot.empty
    @Published var hasResolvedEndpoints = false
    @Published var previewQualityMode: PreviewQualityMode = .ultra
    @Published var effectiveQualityMode: PreviewQualityMode = .ultra
    @Published var audioCaptureSource: AudioCaptureSource = .off
    @Published var thermalOverrideActive = false

    var trustedDevicesCount: Int { trustedDevices.count }

    private let pairingManager = PairingManager()
    private let permissionManager = AccessibilityPermissionManager()
    private lazy var injector = KeyboardInjector(permissionManager: permissionManager)
    private lazy var server = MacWebSocketServer(
        pairingManager: pairingManager,
        injector: injector,
        accessibilityPermissionManager: permissionManager
    )

    private var timerCancellable: AnyCancellable?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "imote.host.network-path")
    private var endpointRefreshTask: Task<Void, Never>?
    private var endpointRefreshGeneration = 0

    init(autoStart: Bool = true) {
        bindServerCallbacks()
        refreshAccessibility(prompt: false)
        if autoStart {
            startServer()
            startPairingTicker()
            refreshPairingSnapshot()
            startPathMonitor()
            refreshReachableEndpoints()
        }
        refreshStartOnLoginStatus()
    }

    func startServer(port: UInt16 = 8989) {
        listenerPort = port
        do {
            try server.start(port: port)
            isListenerRunning = true
            refreshReachableEndpoints()
        } catch {
            isListenerRunning = false
            serverStatus = "Failed to start"
            lastError = error.localizedDescription
        }
    }

    func stopServer() {
        server.stop()
        isListenerRunning = false
        serverStatus = "Stopped"
        connectedPhones = []
        captureRouteStatus = "Unknown"
    }

    func regeneratePairCode() {
        _ = pairingManager.regenerateCode()
        refreshPairingSnapshot()
    }

    func clearTrustedDevices() {
        pairingManager.clearTrustedDevices()
        refreshPairingSnapshot()
    }

    func removeTrustedDevice(id: String) {
        pairingManager.removeTrustedDevice(deviceID: id)
        refreshPairingSnapshot()
    }

    func refreshAccessibility(prompt: Bool) {
        _ = permissionManager.request(prompt: prompt)
        refreshPermissionFlags()
    }

    func requestScreenRecordingPrompt() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissionFlags()
    }

    func openPrivacySettings(_ pane: HostPrivacyPane) {
        let urlString: String
        switch pane {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshReachableEndpoints() {
        endpointRefreshTask?.cancel()
        endpointRefreshGeneration += 1
        let generation = endpointRefreshGeneration
        let port = listenerPort
        endpointRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard Task.isCancelled == false else { return }
            let snapshot = await Task.detached(priority: .utility) {
                HostEndpointCatalog.snapshot(port: port)
            }.value
            guard Task.isCancelled == false else { return }
            self?.applyEndpointSnapshot(snapshot, generation: generation)
        }
    }

    func setStartOnLoginEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            lastError = "Start on Login requires macOS 13 or newer."
            startOnLoginEnabled = false
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStartOnLoginStatus()
        } catch {
            lastError = error.localizedDescription
            refreshStartOnLoginStatus()
        }
    }

    private func bindServerCallbacks() {
        server.onStateChange = { [weak self] state in
            self?.serverStatus = state
            if state == "Stopped" || state.hasPrefix("Listener failed") || state.hasPrefix("Failed") {
                self?.isListenerRunning = false
            } else if state.hasPrefix("Listening") {
                self?.isListenerRunning = true
            }
        }

        server.onClientsChange = { [weak self] clients in
            self?.connectedPhones = clients.map { snapshot in
                let name = snapshot.deviceName ?? snapshot.id.uuidString.prefix(6).description
                return ConnectedPhone(id: snapshot.id, name: name, isPaired: snapshot.isPaired)
            }
        }

        server.onRuntimeError = { [weak self] reason in
            self?.lastError = reason
        }

        server.onCaptureRouteChange = { [weak self] route in
            self?.captureRouteStatus = route
        }

        server.onMediaStatusChange = { [weak self] status in
            self?.previewQualityMode = status.selectedQuality
            self?.effectiveQualityMode = status.effectiveQuality
            self?.audioCaptureSource = status.audioSource
            self?.thermalOverrideActive = status.thermalOverrideActive
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refreshReachableEndpoints()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func applyEndpointSnapshot(_ snapshot: HostEndpointCatalog.Snapshot, generation: Int) {
        guard generation == endpointRefreshGeneration else { return }
        endpointSnapshot = snapshot
        hasResolvedEndpoints = true
    }

    private func startPairingTicker() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPairingSnapshot()
                self.refreshPermissionFlags()
            }
    }

    private func refreshPairingSnapshot() {
        let snapshot = pairingManager.snapshot()
        pairingCode = snapshot.code
        let seconds = max(0, Int(snapshot.expiresAt.timeIntervalSinceNow.rounded(.down)))
        pairingSecondsRemaining = seconds
        trustedDevices = pairingManager.trustedDevices()
    }

    private func refreshPermissionFlags() {
        accessibilityGranted = permissionManager.isTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func refreshStartOnLoginStatus() {
        guard #available(macOS 13.0, *) else {
            startOnLoginEnabled = false
            return
        }
        let status = SMAppService.mainApp.status
        startOnLoginEnabled = (status == .enabled || status == .requiresApproval)
    }
}
