import SwiftUI
import AppKit
import Foundation

@main
struct IMoteMacApp: App {
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
            "iMote Host",
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
                    Text("iMote: control your Mac from your iPhone")
                        .padding()
                }
                .frame(width: 320, height: 100)
            }
        }
    }
}

private final class MacHostCLIRunner: NSObject {
    private let port: UInt16
    private let pairingManager = PairingManager()
    private let permissionManager = AccessibilityPermissionManager()
    private lazy var injector = KeyboardInjector(permissionManager: permissionManager)
    private lazy var server = MacWebSocketServer(
        pairingManager: pairingManager,
        injector: injector,
        accessibilityPermissionManager: permissionManager
    )
    private var pairingTicker: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastPairCode: String = ""
    private var lastConnectedNames: [String] = []

    init(port: UInt16) {
        self.port = port
        super.init()
    }

    func start(showHelp: Bool) {
        if showHelp {
            printUsage()
        }

        print("[iMote] CLI mode enabled")
        print("[iMote] Host: \(Host.current().localizedName ?? "Unknown")")
        print("[iMote] Port: \(port)")

        let accessibilityGranted = permissionManager.request(prompt: false)
        print("[iMote] Accessibility: \(accessibilityGranted ? "granted" : "not granted")")
        if accessibilityGranted == false {
            print("[iMote] Grant at System Settings > Privacy & Security > Accessibility")
        }

        bindServerCallbacks()
        installSignalHandlers()
        startPairingTicker()
        printPairingSnapshot(force: true)

        do {
            try server.start(port: port)
        } catch {
            print("[iMote] Failed to start listener: \(error.localizedDescription)")
            terminate(code: 1)
        }
    }

    private func bindServerCallbacks() {
        server.onStateChange = { state in
            print("[iMote] \(state)")
        }

        server.onClientsChange = { [weak self] clients in
            guard let self else { return }
            let names = clients.map { snapshot in
                snapshot.deviceName ?? snapshot.id.uuidString.prefix(6).description
            }
            guard names != self.lastConnectedNames else { return }
            self.lastConnectedNames = names
            if names.isEmpty {
                print("[iMote] Connected devices: none")
            } else {
                print("[iMote] Connected devices: \(names.joined(separator: ", "))")
            }
        }

        server.onRuntimeError = { reason in
            print("[iMote] Runtime error: \(reason)")
        }
    }

    private func startPairingTicker() {
        pairingTicker = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(handlePairingTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handlePairingTick() {
        printPairingSnapshot(force: false)
    }

    private func printPairingSnapshot(force: Bool) {
        let snapshot = pairingManager.snapshot()
        let remaining = max(0, Int(snapshot.expiresAt.timeIntervalSinceNow.rounded(.down)))
        if force || snapshot.code != lastPairCode || remaining % 15 == 0 {
            lastPairCode = snapshot.code
            print("[iMote] Pairing code: \(snapshot.code) (expires in \(remaining)s)")
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
        print("[iMote] Shutting down")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(code)
        }
    }

    private func printUsage() {
        print("""
        Usage:
          iMote-Host.app/Contents/MacOS/iMote-Host [--cli] [--port 8989] [--help]

        Flags:
          --cli      Run host listener in terminal/headless mode
          --port     Listener port (default: 8989)
          --help     Print this help
        """)
    }
}
