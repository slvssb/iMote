import Combine
import Foundation
import ServiceManagement

@MainActor
final class MacAppState: ObservableObject {
    @Published var serverStatus = "Stopped"
    @Published var connectedDeviceNames: [String] = []
    @Published var pairingCode = "------"
    @Published var pairingSecondsRemaining = 0
    @Published var accessibilityGranted = false
    @Published var trustedDevicesCount = 0
    @Published var lastError: String?
    @Published var startOnLoginEnabled = false
    @Published var captureRouteStatus = "Unknown"
    @Published var availableDisplays: [HostDisplayInfo] = []
    @Published var selectedDisplayID: UInt32 = HostDisplayPreferences.selectedDisplayID
    @Published var virtualDisplayWhenHeadless = HostDisplayPreferences.virtualDisplayWhenHeadless

    private let pairingManager = PairingManager()
    private let permissionManager = AccessibilityPermissionManager()
    private lazy var injector = KeyboardInjector(permissionManager: permissionManager)
    private lazy var server = MacWebSocketServer(
        pairingManager: pairingManager,
        injector: injector,
        accessibilityPermissionManager: permissionManager
    )

    private var timerCancellable: AnyCancellable?

    init(autoStart: Bool = true) {
        bindServerCallbacks()
        refreshAccessibility(prompt: false)
        if autoStart {
            startServer()
            startPairingTicker()
            refreshPairingSnapshot()
        }
        refreshStartOnLoginStatus()
    }

    func startServer() {
        do {
            try server.start(port: 8989)
        } catch {
            serverStatus = "Failed to start"
            lastError = error.localizedDescription
        }
    }

    func stopServer() {
        server.stop()
        serverStatus = "Stopped"
        connectedDeviceNames = []
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

    func refreshAccessibility(prompt: Bool) {
        _ = permissionManager.request(prompt: prompt)
        accessibilityGranted = permissionManager.isTrusted()
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
        }

        server.onClientsChange = { [weak self] clients in
            self?.connectedDeviceNames = clients.map { snapshot in
                snapshot.deviceName ?? snapshot.id.uuidString.prefix(6).description
            }
        }

        server.onRuntimeError = { [weak self] reason in
            self?.lastError = reason
        }

        server.onCaptureRouteChange = { [weak self] route in
            self?.captureRouteStatus = route
        }

        server.onDisplayCatalogChange = { [weak self] snapshot in
            self?.captureRouteStatus = snapshot.routeLabel
            self?.availableDisplays = snapshot.displays
            self?.selectedDisplayID = snapshot.selectedDisplayID
            self?.virtualDisplayWhenHeadless = snapshot.virtualDisplayWhenHeadless
        }
    }

    func setVirtualDisplayWhenHeadless(_ enabled: Bool) {
        virtualDisplayWhenHeadless = enabled
        server.setVirtualDisplayWhenHeadless(enabled)
    }

    func selectDisplay(id: UInt32) {
        selectedDisplayID = id
        server.selectCaptureDisplay(id: id)
    }

    private func startPairingTicker() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPairingSnapshot()
            }
    }

    private func refreshPairingSnapshot() {
        let snapshot = pairingManager.snapshot()
        pairingCode = snapshot.code
        let seconds = max(0, Int(snapshot.expiresAt.timeIntervalSinceNow.rounded(.down)))
        pairingSecondsRemaining = seconds
        trustedDevicesCount = pairingManager.trustedDevicesCount()
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
