import AppKit
import SwiftUI

struct HostMainWindow: View {
    @ObservedObject var appState: MacAppState

    var body: some View {
        NavigationStack {
            Form {
                HostListenerSection(
                    status: appState.serverStatus,
                    captureRoute: appState.captureRouteStatus,
                    listenerPort: appState.listenerPort,
                    isListenerRunning: appState.isListenerRunning,
                    lastError: appState.lastError,
                    onPortDraft: { appState.noteListenerPortDraft($0) },
                    onStart: { portText in
                        guard appState.applyListenerPort(portText) else { return }
                        appState.startServer()
                    },
                    onStop: { appState.stopServer() }
                )
                HostPairingSection(
                    code: appState.pairingCode,
                    secondsRemaining: appState.pairingSecondsRemaining,
                    hostFingerprint: appState.hostFingerprint,
                    onRegenerate: { appState.regeneratePairCode() }
                )
                HostAddressesSection(
                    endpoints: appState.endpointSnapshot.endpoints,
                    isResolving: appState.hasResolvedEndpoints == false,
                    guidance: appState.endpointSnapshot.tailscale.guidance,
                    onRefresh: { appState.refreshReachableEndpoints() }
                )
                HostConnectedDevicesSection(phones: appState.connectedPhones)
                HostTrustedDevicesSection(
                    devices: appState.trustedDevices,
                    onRemove: { appState.removeTrustedDevice(id: $0) },
                    onClear: { appState.clearTrustedDevices() }
                )
                HostPermissionsSection(
                    accessibilityGranted: appState.accessibilityGranted,
                    screenRecordingGranted: appState.screenRecordingGranted,
                    onRequestAccessibility: { appState.refreshAccessibility(prompt: true) },
                    onRequestScreenRecording: { appState.requestScreenRecordingPrompt() },
                    onOpenAccessibility: { appState.openPrivacySettings(.accessibility) },
                    onOpenScreenRecording: { appState.openPrivacySettings(.screenRecording) }
                )
                HostStreamSection(
                    selectedQuality: appState.previewQualityMode,
                    effectiveQuality: appState.effectiveQualityMode,
                    audioSource: appState.audioCaptureSource,
                    thermalOverrideActive: appState.thermalOverrideActive
                )
                HostLoginSection(
                    isEnabled: appState.startOnLoginEnabled,
                    onChange: { appState.setStartOnLoginEnabled($0) }
                )
            }
            .formStyle(.grouped)
            .navigationTitle("iMote Host")
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

private struct HostListenerSection: View {
    let status: String
    let captureRoute: String
    let listenerPort: UInt16
    let isListenerRunning: Bool
    let lastError: String?
    let onPortDraft: (String) -> Void
    let onStart: (String) -> Void
    let onStop: () -> Void
    @State private var portText = ""

    var body: some View {
        Section {
            LabeledContent("Listener") {
                Label(status, systemImage: isListenerRunning ? "circle.fill" : "circle")
                    .foregroundStyle(isListenerRunning ? Color.green : Color.secondary)
                    .labelStyle(.titleAndIcon)
            }
            LabeledContent("Port") {
                TextField("8989", text: $portText)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 96)
                    .disabled(isListenerRunning)
                    .onAppear {
                        if portText.isEmpty {
                            portText = String(listenerPort)
                        }
                    }
                    .onChange(of: listenerPort) { _, newValue in
                        portText = String(newValue)
                    }
                    .onChange(of: portText) { _, newValue in
                        onPortDraft(newValue)
                    }
                    .onSubmit {
                        onStart(portText)
                    }
            }
            LabeledContent("Capture") {
                Text(captureRoute)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Start Listener") {
                    onStart(portText)
                }
                    .disabled(isListenerRunning)
                Button("Stop Listener", action: onStop)
                    .disabled(isListenerRunning == false)
            }
            if let lastError, lastError.isEmpty == false {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("The listener accepts connections on every interface, including Tailscale when it is connected. Bonjour discovery stays on the local network. Stop the listener to change the port.")
        }
    }
}

private struct HostPairingSection: View {
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

private struct HostAddressesSection: View {
    let endpoints: [HostEndpoint]
    let isResolving: Bool
    let guidance: String
    let onRefresh: () -> Void

    var body: some View {
        Section {
            if endpoints.isEmpty {
                Text(isResolving ? "Looking up addresses…" : "No reachable address yet.")
                    .foregroundStyle(.secondary)
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

private struct HostAddressRow: View {
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

private struct HostConnectedDevicesSection: View {
    let phones: [ConnectedPhone]

    var body: some View {
        Section("Connected iPhones") {
            if phones.isEmpty {
                Text("No active client")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(phones) { phone in
                    LabeledContent(phone.name) {
                        Text(phone.isPaired ? "Paired" : "Connecting")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct HostTrustedDevicesSection: View {
    let devices: [TrustedDeviceRecord]
    let onRemove: (String) -> Void
    let onClear: () -> Void
    @State private var isClearConfirmationPresented = false

    var body: some View {
        Section {
            if devices.isEmpty {
                Text("No trusted devices")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName)
                            Text(device.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if let fingerprint = device.fingerprint {
                                Text(fingerprint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 12)
                        Button("Remove") {
                            onRemove(device.id)
                        }
                    }
                }
            }
            Button("Clear Trusted Devices", role: .destructive) {
                isClearConfirmationPresented = true
            }
            .disabled(devices.isEmpty)
        } header: {
            Text("Trusted Devices")
        } footer: {
            Text("Trust lets that iPhone reconnect without a new pairing code. Removing it also deletes its pinned signing key. On a first pair, compare the fingerprint with the iPhone.")
        }
        .alert("Clear trusted devices?", isPresented: $isClearConfirmationPresented) {
            Button("Clear", role: .destructive, action: onClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paired iPhones will need a new pairing code. Their pinned signing keys are deleted too.")
        }
    }
}

private struct HostPermissionsSection: View {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let onRequestAccessibility: () -> Void
    let onRequestScreenRecording: () -> Void
    let onOpenAccessibility: () -> Void
    let onOpenScreenRecording: () -> Void

    var body: some View {
        Section {
            HostPermissionRow(
                title: "Accessibility",
                detail: "Keyboard and pointer",
                granted: accessibilityGranted,
                onRequest: onRequestAccessibility,
                onOpenSettings: onOpenAccessibility
            )
            HostPermissionRow(
                title: "Screen Recording",
                detail: "Live preview",
                granted: screenRecordingGranted,
                onRequest: onRequestScreenRecording,
                onOpenSettings: onOpenScreenRecording
            )
        } header: {
            Text("Permissions")
        } footer: {
            Text("Remote control needs Accessibility. Live preview also needs Screen Recording.")
        }
    }
}

private struct HostPermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(granted ? "Granted" : "Not granted")
                    .foregroundStyle(granted ? Color.green : Color.red)
                if granted == false {
                    Button("Request", action: onRequest)
                    Button("Settings", action: onOpenSettings)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HostStreamSection: View {
    let selectedQuality: PreviewQualityMode
    let effectiveQuality: PreviewQualityMode
    let audioSource: AudioCaptureSource
    let thermalOverrideActive: Bool

    var body: some View {
        Section {
            LabeledContent("Preview") {
                Text(effectiveQuality.menuTitle)
            }
            if thermalOverrideActive, selectedQuality != effectiveQuality {
                LabeledContent("Requested") {
                    Text(selectedQuality.menuTitle)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Audio") {
                Text(audioSource.menuTitle)
            }
            LabeledContent("Thermal override") {
                Text(thermalOverrideActive ? "On" : "Off")
                    .foregroundStyle(thermalOverrideActive ? Color.orange : Color.secondary)
            }
        } header: {
            Text("Stream")
        } footer: {
            Text("The connected iPhone chooses preview quality and the audio source. Under thermal pressure the host steps the preview down to Balanced.")
        }
    }
}

private struct HostLoginSection: View {
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Section {
            Toggle(
                "Start on Login",
                isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        onChange(newValue)
                    }
                )
            )
        } footer: {
            Text("Opens iMote Host when you sign in to this Mac. The menu-bar extra keeps running if you close this window.")
        }
    }
}

private extension PreviewQualityMode {
    var menuTitle: String {
        switch self {
        case .balanced: "Balanced"
        case .ultra: "Ultra"
        }
    }
}

private extension AudioCaptureSource {
    var menuTitle: String {
        switch self {
        case .off: "Off"
        case .systemOutput: "System"
        case .microphone: "Microphone"
        case .systemAndMicrophone: "System and Microphone"
        }
    }
}
