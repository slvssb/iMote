import Combine
import Foundation

@MainActor
final class MacAppState: ObservableObject {
    @Published var serverStatus = "Stopped"
    @Published var connectedDeviceNames: [String] = []
    @Published var pairingCode = "------"
    @Published var pairingSecondsRemaining = 0
    @Published var accessibilityGranted = false
    @Published var lastError: String?

    private let pairingManager = PairingManager()
    private let permissionManager = AccessibilityPermissionManager()
    private lazy var injector = KeyboardInjector(permissionManager: permissionManager)
    private lazy var server = MacWebSocketServer(pairingManager: pairingManager, injector: injector)

    private var timerCancellable: AnyCancellable?

    init() {
        bindServerCallbacks()
        refreshAccessibility(prompt: false)
        startServer()
        startPairingTicker()
        refreshPairingSnapshot()
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
    }

    func regeneratePairCode() {
        _ = pairingManager.regenerateCode()
        refreshPairingSnapshot()
    }

    func refreshAccessibility(prompt: Bool) {
        _ = permissionManager.request(prompt: prompt)
        accessibilityGranted = permissionManager.isTrusted()
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
    }
}
