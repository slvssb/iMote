import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var appState: MacAppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Show Window") {
                NSApp.activate()
                openWindow(id: "host-main")
            }
            header
            Divider()
            addressSection
            Divider()
            pairingSection
            Divider()
            accessibilitySection
            Divider()
            connectionSection
            Divider()
            trustedDevicesSection
            Divider()
            startOnLoginSection
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 320)
    }

    private var addressSection: some View {
        let highlights = appState.endpointSnapshot.menuHighlights
        return VStack(alignment: .leading, spacing: 6) {
            Text("Reachable")
                .font(.subheadline.weight(.semibold))
            if appState.hasResolvedEndpoints == false {
                Text("Looking up addresses…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if highlights.isEmpty {
                Text("No reachable address yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(highlights) { endpoint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(endpoint.pasteboardValue)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if let preferred = highlights.first {
                    Button("Copy \(preferred.title)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(preferred.pasteboardValue, forType: .string)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iMote Host")
                .font(.headline)
            Text(appState.serverStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Capturing: \(appState.captureRouteStatus)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pairing Code")
                .font(.subheadline.weight(.semibold))
            Text(appState.pairingCode)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .tracking(4)
            Text("Expires in \(appState.pairingSecondsRemaining)s")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Regenerate Code") {
                appState.regeneratePairCode()
            }
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility Permission")
                .font(.subheadline.weight(.semibold))
            Text(appState.accessibilityGranted ? "Granted" : "Not granted")
                .font(.caption)
                .foregroundStyle(appState.accessibilityGranted ? Color.green : Color.red)
            Text(appState.screenRecordingGranted ? "Screen Recording: Granted" : "Screen Recording: Not granted")
                .font(.caption)
                .foregroundStyle(appState.screenRecordingGranted ? Color.green : Color.secondary)
            Button("Request / Open Prompt") {
                appState.refreshAccessibility(prompt: true)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected iPhones")
                .font(.subheadline.weight(.semibold))
            if appState.connectedPhones.isEmpty {
                Text("No active client")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.connectedPhones) { phone in
                    Text("• \(phone.name)")
                        .font(.caption)
                }
            }
        }
    }

    private var trustedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trusted Devices")
                .font(.subheadline.weight(.semibold))
            Text("\(appState.trustedDevices.count) trusted")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.hostFingerprint.isEmpty == false {
                Text("This Mac \(appState.hostFingerprint)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if let fingerprint = appState.lastPinnedFingerprint {
                Text(appState.lastPinnedFingerprintIsNew ? "New iPhone \(fingerprint)" : "iPhone \(fingerprint)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button("Clear trusted devices") {
                appState.clearTrustedDevices()
            }
        }
    }

    private var controls: some View {
        HStack {
            Button("Start Listener") {
                appState.startServer()
            }
            Button("Stop Listener") {
                appState.stopServer()
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var startOnLoginSection: some View {
        Toggle("Start on Login", isOn: Binding(
            get: { appState.startOnLoginEnabled },
            set: { appState.setStartOnLoginEnabled($0) }
        ))
        .font(.subheadline.weight(.semibold))
    }
}
