import SwiftUI
import AppKit
import Combine
import Foundation

final class HostAppDelegate: NSObject, NSApplicationDelegate {
    var suppressWindows = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if suppressWindows {
            return false
        }
        sender.activate()
        if flag == false {
            for window in sender.windows where window.level == .normal {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

@main
struct IMoteMacApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate

    private struct LaunchOptions {
        let cliMode: Bool
        let port: UInt16?
        let showHelp: Bool

        struct ParseError: Error, CustomStringConvertible {
            let description: String
        }

        static func parse(_ args: [String]) throws -> LaunchOptions {
            var cliMode = false
            var showHelp = false
            var port: UInt16?

            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--cli":
                    cliMode = true
                case "--help", "-h":
                    showHelp = true
                case "--port":
                    guard index + 1 < args.count else {
                        throw ParseError(description: "--port needs a number from 1 to 65535.")
                    }
                    let raw = args[index + 1]
                    guard let value = UInt16(raw), value != 0 else {
                        throw ParseError(description: "Invalid --port '\(raw)'. Use a number from 1 to 65535.")
                    }
                    port = value
                    index += 1
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
        let options: LaunchOptions
        do {
            options = try LaunchOptions.parse(CommandLine.arguments)
        } catch {
            let message = (error as? LaunchOptions.ParseError)?.description ?? error.localizedDescription
            fputs("[iMote] \(message)\n", stderr)
            fputs("[iMote] Run with --help for usage.\n", stderr)
            exit(64)
        }
        self.launchOptions = options
        if options.cliMode {
            let cliPort = options.port ?? MacAppState.storedListenerPort()
            let state = MacAppState(autoStart: false, initialPort: cliPort)
            _appState = StateObject(wrappedValue: state)
            let runner = MacHostCLIRunner(appState: state, port: cliPort)
            self.cliRunner = runner
            runner.start(showHelp: options.showHelp)
            NSApplication.shared.setActivationPolicy(.prohibited)
        } else {
            _appState = StateObject(
                wrappedValue: MacAppState(
                    autoStart: true,
                    initialPort: options.port,
                    rememberInitialPort: options.port != nil
                )
            )
            self.cliRunner = nil
        }
        appDelegate.suppressWindows = options.cliMode
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

        Window("iMote Host", id: "host-main") {
            if launchOptions.cliMode {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                HostMainWindow(appState: appState)
            }
        }
        .defaultLaunchBehavior(launchOptions.cliMode ? .suppressed : .presented)
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
private final class MacHostCLIRunner: NSObject {
    private let appState: MacAppState
    private let port: UInt16
    private var pairingTicker: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastPairCode: String = ""
    private var lastConnectedNames: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    init(appState: MacAppState, port: UInt16) {
        self.appState = appState
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

        appState.refreshAccessibility(prompt: false)
        let accessibilityGranted = appState.accessibilityGranted
        print("[iMote] Accessibility: \(accessibilityGranted ? "granted" : "not granted")")
        if accessibilityGranted == false {
            print("[iMote] Grant at System Settings > Privacy & Security > Accessibility")
        }

        print("[iMote] This Mac fingerprint: \(appState.hostFingerprint)")
        bindPrints()
        installSignalHandlers()
        startPairingTicker()
        printPairingSnapshot(force: true)
        appState.startServer()
        if appState.isListenerRunning == false {
            print("[iMote] Failed to start listener: \(appState.lastError ?? "unknown error")")
            terminate(code: 1)
            return
        }

        printReachableEndpoints()
    }

    private func printReachableEndpoints() {
        let snapshot = HostEndpointCatalog.snapshot(port: port)
        if snapshot.endpoints.isEmpty {
            print("[iMote] Reachable addresses: none")
        } else {
            print("[iMote] Reachable addresses:")
            for endpoint in snapshot.endpoints {
                let interfaceNote = endpoint.interfaceName.map { " (\($0))" } ?? ""
                print("[iMote]   \(endpoint.title)  \(endpoint.pasteboardValue)\(interfaceNote)")
            }
        }
        switch snapshot.tailscale {
        case .online:
            print("[iMote] Tailscale: available")
        case .notRunning:
            print("[iMote] Tailscale: installed, no tailnet address")
        case .notDetected:
            print("[iMote] Tailscale: not detected")
        }
    }

    private func bindPrints() {
        appState.$serverStatus
            .dropFirst()
            .sink { status in
                print("[iMote] \(status)")
            }
            .store(in: &cancellables)

        appState.$connectedPhones
            .dropFirst()
            .sink { [weak self] phones in
                guard let self else { return }
                let names = phones.map(\.name)
                guard names != self.lastConnectedNames else { return }
                self.lastConnectedNames = names
                if names.isEmpty {
                    print("[iMote] Connected devices: none")
                } else {
                    print("[iMote] Connected devices: \(names.joined(separator: ", "))")
                }
            }
            .store(in: &cancellables)

        appState.$lastError
            .dropFirst()
            .sink { reason in
                guard let reason, reason.isEmpty == false else { return }
                print("[iMote] Runtime error: \(reason)")
            }
            .store(in: &cancellables)

        appState.$lastPinnedFingerprint
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] fingerprint in
                guard let self, let fingerprint else { return }
                let label = self.appState.lastPinnedFingerprintIsNew ? "New iPhone fingerprint" : "iPhone fingerprint"
                print("[iMote] \(label): \(fingerprint)")
            }
            .store(in: &cancellables)
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
        let code = appState.pairingCode
        let remaining = appState.pairingSecondsRemaining
        if force || code != lastPairCode || remaining % 15 == 0 {
            lastPairCode = code
            print("[iMote] Pairing code: \(code) (expires in \(remaining)s)")
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.terminate(code: 0)
            }
        }
        sigint.resume()
        signalSources.append(sigint)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.terminate(code: 0)
            }
        }
        sigterm.resume()
        signalSources.append(sigterm)
    }

    private func terminate(code: Int32) {
        pairingTicker?.invalidate()
        pairingTicker = nil
        appState.stopServer()
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
          --port     Listener port from 1 to 65535. Invalid values exit.
          --help     Print this help

        Prints listener state, the pairing code, permissions, LAN and Tailscale addresses, and connected devices.
        """)
    }
}
