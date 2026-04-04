import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var appState: MacAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            pairingSection
            Divider()
            accessibilitySection
            Divider()
            connectionSection
            Divider()
            trustedDevicesSection
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iMote Host")
                .font(.headline)
            Text(appState.serverStatus)
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
            Button("Request / Open Prompt") {
                appState.refreshAccessibility(prompt: true)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected iPhones")
                .font(.subheadline.weight(.semibold))
            if appState.connectedDeviceNames.isEmpty {
                Text("No active client")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.connectedDeviceNames, id: \.self) { name in
                    Text("• \(name)")
                        .font(.caption)
                }
            }
        }
    }

    private var trustedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trusted Devices")
                .font(.subheadline.weight(.semibold))
            Text("\(appState.trustedDevicesCount) trusted")
                .font(.caption)
                .foregroundStyle(.secondary)
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
}
