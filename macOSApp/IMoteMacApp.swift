import SwiftUI
import AppKit
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
        let explicitPort: UInt16?
        let showHelp: Bool

        enum ParseError: Error, CustomStringConvertible {
            case missingPortValue
            case invalidPort(String)

            var description: String {
                switch self {
                case .missingPortValue:
                    return "--port needs a value from 1 to 65535."
                case .invalidPort(let raw):
                    return "--port \(raw) is not a port from 1 to 65535."
                }
            }
        }

        static func parse(_ args: [String]) throws -> LaunchOptions {
            var cliMode = false
            var showHelp = false
            var explicitPort: UInt16?

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
                        throw ParseError.missingPortValue
                    }
                    let raw = args[index + 1]
                    guard let value = UInt16(raw), (1...65_535).contains(Int(value)) else {
                        throw ParseError.invalidPort(raw)
                    }
                    explicitPort = value
                    index += 1
                default:
                    break
                }
                index += 1
            }

            return LaunchOptions(cliMode: cliMode, explicitPort: explicitPort, showHelp: showHelp)
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
            fputs("iMote Host: \(error)\n", stderr)
            exit(64)
        }
        self.launchOptions = options
        let state = MacAppState(autoStart: options.cliMode == false, initialPort: options.explicitPort)
        _appState = StateObject(wrappedValue: state)
        if options.cliMode {
            let runner = MacHostCLIRunner(appState: state)
            self.cliRunner = runner
            runner.start(showHelp: options.showHelp)
            NSApplication.shared.setActivationPolicy(.prohibited)
        } else {
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
    private var pairingTicker: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var lastPairCode: String = ""
    private var lastConnectedNames: [String] = []
    private var lastStatus: String = ""
    private var lastRuntimeError: String = ""
    private var lastPinnedFingerprint: String = ""
    private var lastCaptureRoute: String = ""

    init(appState: MacAppState) {
        self.appState = appState
        super.init()
    }

    func start(showHelp: Bool) {
        if showHelp {
            printUsage()
        }

        print("[iMote] CLI mode enabled")
        print("[iMote] Host: \(Host.current().localizedName ?? "Unknown")")
        print("[iMote] Port: \(appState.listenerPort)")
        print("[iMote] Accessibility: \(appState.accessibilityGranted ? "granted" : "not granted")")
        if appState.accessibilityGranted == false {
            print("[iMote] Grant at System Settings > Privacy & Security > Accessibility")
        }
        print("[iMote] This Mac fingerprint: \(appState.hostFingerprint)")

        installSignalHandlers()
        appState.startServer()
        if appState.isListenerRunning == false {
            print("[iMote] Failed to start listener: \(appState.lastError ?? "unknown error")")
            terminate(code: 1)
            return
        }

        printReachableEndpoints()
        startPairingTicker()
        printSnapshot(force: true)
    }

    private func printReachableEndpoints() {
        let snapshot = HostEndpointCatalog.snapshot(port: appState.listenerPort)
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
        printSnapshot(force: false)
    }

    private func printSnapshot(force: Bool) {
        let code = appState.pairingCode
        let remaining = appState.pairingSecondsRemaining
        if force || code != lastPairCode || remaining % 15 == 0 {
            lastPairCode = code
            print("[iMote] Pairing code: \(code) (expires in \(remaining)s)")
        }

        if appState.serverStatus != lastStatus {
            lastStatus = appState.serverStatus
            print("[iMote] \(appState.serverStatus)")
        }

        let names = appState.connectedPhones.map(\.name)
        if names != lastConnectedNames {
            lastConnectedNames = names
            if names.isEmpty {
                print("[iMote] Connected devices: none")
            } else {
                print("[iMote] Connected devices: \(names.joined(separator: ", "))")
            }
        }

        if let fingerprint = appState.lastPinnedFingerprint, fingerprint != lastPinnedFingerprint {
            lastPinnedFingerprint = fingerprint
            let label = appState.lastPinnedFingerprintIsNew ? "New iPhone fingerprint" : "iPhone fingerprint"
            print("[iMote] \(label): \(fingerprint)")
        }

        if appState.captureRouteStatus != lastCaptureRoute {
            lastCaptureRoute = appState.captureRouteStatus
            print("[iMote] Capturing: \(appState.captureRouteStatus)")
        }

        if let error = appState.lastError, error.isEmpty == false, error != lastRuntimeError {
            lastRuntimeError = error
            print("[iMote] Runtime error: \(error)")
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
          --port     Listener port from 1 to 65535 (default: 8989)
          --help     Print this help

        A missing or non-numeric --port exits instead of listening on 8989.
        --cli uses the same listener and pairing code as the host window.

        Prints listener state, the pairing code, permissions, LAN and Tailscale addresses, and connected devices.
        """)
    }
}
