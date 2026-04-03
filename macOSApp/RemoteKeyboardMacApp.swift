import SwiftUI
import AppKit
import Foundation

@main
struct RemoteKeyboardMacApp: App {
    private struct LaunchOptions {
        let cliMode: Bool
        let port: UInt16
        let showHelp: Bool

        static func parse(_ args: [String]) -> LaunchOptions {
            var cliMode = false
            var showHelp = false
            var port: UInt16 = 8989

            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--cli":
                    cliMode = true
                case "--help", "-h":
                    showHelp = true
                case "--port":
                    if index + 1 < args.count, let value = UInt16(args[index + 1]) {
                        port = value
                        index += 1
                    }
                default:
                    break
                }
                index += 1
            }

            return LaunchOptions(cliMode: cliMode, port: port, showHelp: showHelp)
        }
    }

    @StateObject private var appState: MacAppState
    private let launchOptions: LaunchOptions
    private let cliRunner: MacHostCLIRunner?

    init() {
        let options = LaunchOptions.parse(CommandLine.arguments)
        self.launchOptions = options
        if options.cliMode {
            _appState = StateObject(wrappedValue: MacAppState(autoStart: false))
            let runner = MacHostCLIRunner(port: options.port)
            self.cliRunner = runner
            runner.start(showHelp: options.showHelp)
            NSApplication.shared.setActivationPolicy(.prohibited)
        } else {
            _appState = StateObject(wrappedValue: MacAppState())
            self.cliRunner = nil
        }
    }

    var body: some Scene {
        MenuBarExtra(
            "iPhone Keyboard Host",
            systemImage: "keyboard",
            isInserted: .constant(launchOptions.cliMode == false)
        ) {
            MenuBarMenuView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if launchOptions.cliMode {
                EmptyView()
            } else {
                VStack {
                    Text("iPhone Keyboard Host runs in the menu bar.")
                        .padding()
                }
                .frame(width: 320, height: 100)
            }
        }
    }
}

private final class MacHostCLIRunner {
    private let port: UInt16
    private let pairingManager = PairingManager()
    private let permissionManager = AccessibilityPermissionManager()
    private lazy var injector = KeyboardInjector(permissionManager: permissionManager)
    private lazy var server = MacWebSocketServer(pairingManager: pairingManager, injector: injector)
    private var pairingTicker: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastPairCode: String = ""
    private var lastConnectedNames: [String] = []

    init(port: UInt16) {
        self.port = port
    }

    func start(showHelp: Bool) {
        if showHelp {
            printUsage()
        }

        print("[iPhoneKeyboard] CLI mode enabled")
        print("[iPhoneKeyboard] Host: \(Host.current().localizedName ?? "Unknown")")
        print("[iPhoneKeyboard] Port: \(port)")

        let accessibilityGranted = permissionManager.request(prompt: false)
        print("[iPhoneKeyboard] Accessibility: \(accessibilityGranted ? "granted" : "not granted")")
        if accessibilityGranted == false {
            print("[iPhoneKeyboard] Grant at System Settings > Privacy & Security > Accessibility")
        }

        bindServerCallbacks()
        installSignalHandlers()
        startPairingTicker()
        printPairingSnapshot(force: true)

        do {
            try server.start(port: port)
        } catch {
            print("[iPhoneKeyboard] Failed to start listener: \(error.localizedDescription)")
            terminate(code: 1)
        }
    }

    private func bindServerCallbacks() {
        server.onStateChange = { state in
            print("[iPhoneKeyboard] \(state)")
        }

        server.onClientsChange = { [weak self] clients in
            guard let self else { return }
            let names = clients.map { snapshot in
                snapshot.deviceName ?? snapshot.id.uuidString.prefix(6).description
            }
            guard names != self.lastConnectedNames else { return }
            self.lastConnectedNames = names
            if names.isEmpty {
                print("[iPhoneKeyboard] Connected devices: none")
            } else {
                print("[iPhoneKeyboard] Connected devices: \(names.joined(separator: ", "))")
            }
        }

        server.onRuntimeError = { reason in
            print("[iPhoneKeyboard] Runtime error: \(reason)")
        }
    }

    private func startPairingTicker() {
        pairingTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.printPairingSnapshot(force: false)
        }
    }

    private func printPairingSnapshot(force: Bool) {
        let snapshot = pairingManager.snapshot()
        let remaining = max(0, Int(snapshot.expiresAt.timeIntervalSinceNow.rounded(.down)))
        if force || snapshot.code != lastPairCode || remaining % 15 == 0 {
            lastPairCode = snapshot.code
            print("[iPhoneKeyboard] Pairing code: \(snapshot.code) (expires in \(remaining)s)")
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            self?.terminate(code: 0)
        }
        sigint.resume()
        signalSources.append(sigint)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            self?.terminate(code: 0)
        }
        sigterm.resume()
        signalSources.append(sigterm)
    }

    private func terminate(code: Int32) {
        pairingTicker?.invalidate()
        pairingTicker = nil
        server.stop()
        print("[iPhoneKeyboard] Shutting down")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(code)
        }
    }

    private func printUsage() {
        print("""
        Usage:
          iPhoneKeyboard-Mac.app/Contents/MacOS/iPhoneKeyboard-Mac [--cli] [--port 8989] [--help]

        Flags:
          --cli      Run host listener in terminal/headless mode
          --port     Listener port (default: 8989)
          --help     Print this help
        """)
    }
}
