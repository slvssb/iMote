import AppKit
import SwiftUI

struct HostOverviewView: View {
    @ObservedObject var appState: MacAppState

    var body: some View {
        Form {
            Section {
                LabeledContent("Listener") {
                    Label(appState.serverStatus, systemImage: appState.isListenerRunning ? "circle.fill" : "circle")
                        .foregroundStyle(appState.isListenerRunning ? Color.green : Color.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel(appState.isListenerRunning ? "Listening. \(appState.serverStatus)" : "Not listening. \(appState.serverStatus)")
                }
                LabeledContent("Port", value: String(appState.listenerPort))
                LabeledContent("Capture display") {
                    Text(captureDisplayTitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Virtual display when no monitor") {
                    Text(appState.virtualDisplayWhenHeadless ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Start Listener") {
                        appState.startServer()
                    }
                    .disabled(appState.isListenerRunning)
                    Button("Stop Listener") {
                        appState.stopServer()
                    }
                    .disabled(appState.isListenerRunning == false)
                }
                if let lastError = appState.lastError, lastError.isEmpty == false {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("The listener accepts connections on every interface, including Tailscale when it is connected. Bonjour discovery stays on the local network. Change the port in Settings.")
            }

            HostAddressesSection(
                endpoints: appState.endpointSnapshot.endpoints,
                isResolving: appState.hasResolvedEndpoints == false,
                guidance: appState.endpointSnapshot.tailscale.guidance,
                onRefresh: { appState.refreshReachableEndpoints() }
            )

            HostPairingSection(
                code: appState.pairingCode,
                secondsRemaining: appState.pairingSecondsRemaining,
                hostFingerprint: appState.hostFingerprint,
                onRegenerate: { appState.regeneratePairCode() }
            )
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
    }

    private var captureDisplayTitle: String {
        if let captured = appState.availableDisplays.first(where: \.isCaptured) {
            return captured.menuTitle
        }
        return appState.captureRouteStatus
    }
}

struct HostPairingSection: View {
    let code: String
    let secondsRemaining: Int
    let hostFingerprint: String
    let onRegenerate: () -> Void

    var body: some View {
        Section("Pairing") {
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel("Pairing code \(code)")
            Text("Expires in \(secondsRemaining)s")
                .foregroundStyle(.secondary)
            if hostFingerprint.isEmpty == false {
                LabeledContent("This Mac") {
                    Text(hostFingerprint)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            Button("Regenerate Code", action: onRegenerate)
        }
    }
}

struct HostAddressesSection: View {
    let endpoints: [HostEndpoint]
    let isResolving: Bool
    let guidance: String
    let onRefresh: () -> Void

    var body: some View {
        Section {
            if endpoints.isEmpty {
                ContentUnavailableView(
                    isResolving ? "Looking up addresses" : "No reachable address",
                    systemImage: "network.slash",
                    description: { Text(isResolving ? "Checking this Mac's LAN and Tailscale addresses." : "No reachable address yet.") }
                )
            } else {
                ForEach(endpoints) { endpoint in
                    HostAddressRow(endpoint: endpoint)
                }
            }
            Button("Refresh Addresses", action: onRefresh)
        } header: {
            Text("Reachable")
        } footer: {
            Text(guidance)
        }
    }
}

struct HostAddressRow: View {
    let endpoint: HostEndpoint
    @State private var didCopy = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(endpoint.pasteboardValue)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(didCopy ? "Copied" : "Copy") {
                    copy()
                }
                .accessibilityLabel(didCopy ? "Copied \(endpoint.title)" : "Copy \(endpoint.title)")
            }
        } label: {
            Label(endpoint.title, systemImage: endpoint.systemImage)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(endpoint.title) \(endpoint.pasteboardValue)")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.pasteboardValue, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }
}
