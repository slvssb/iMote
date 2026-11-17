import SwiftUI

struct HostSettingsView: View {
    @ObservedObject var appState: MacAppState

    var body: some View {
        Form {
            HostPortSection(
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
            HostDisplaySection(
                displays: appState.availableDisplays,
                selectedDisplayID: appState.selectedDisplayID,
                virtualDisplayWhenHeadless: appState.virtualDisplayWhenHeadless,
                captureRoute: appState.captureRouteStatus,
                onSelectDisplay: { appState.selectDisplay(id: $0) },
                onVirtualDisplay: { appState.setVirtualDisplayWhenHeadless($0) }
            )
            HostStreamSection(
                selectedQuality: appState.previewQualityMode,
                effectiveQuality: appState.effectiveQualityMode,
                audioSource: appState.audioCaptureSource,
                thermalOverrideActive: appState.thermalOverrideActive
            )
            HostPermissionsSection(
                accessibilityGranted: appState.accessibilityGranted,
                screenRecordingGranted: appState.screenRecordingGranted,
                onRequestAccessibility: { appState.refreshAccessibility(prompt: true) },
                onRequestScreenRecording: { appState.requestScreenRecordingPrompt() },
                onOpenAccessibility: { appState.openPrivacySettings(.accessibility) },
                onOpenScreenRecording: { appState.openPrivacySettings(.screenRecording) }
            )
            HostLoginSection(
                isEnabled: appState.startOnLoginEnabled,
                onChange: { appState.setStartOnLoginEnabled($0) }
            )
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

private struct HostPortSection: View {
    let listenerPort: UInt16
    let isListenerRunning: Bool
    let lastError: String?
    let onPortDraft: (String) -> Void
    let onStart: (String) -> Void
    let onStop: () -> Void
    @State private var portText = ""

    var body: some View {
        Section {
            LabeledContent("Port") {
                TextField("8989", text: $portText)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 96)
                    .disabled(isListenerRunning)
                    .accessibilityLabel("Listener port")
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
            HStack {
                Button("Start Listener") {
                    onStart(portText)
                }
                .disabled(isListenerRunning)
                Button("Stop Listener") {
                    onStop()
                }
                .disabled(isListenerRunning == false)
            }
            if let lastError, lastError.isEmpty == false {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Port")
        } footer: {
            Text("Stop the listener to change the port.")
        }
    }
}

private struct HostDisplaySection: View {
    let displays: [HostDisplayInfo]
    let selectedDisplayID: UInt32
    let virtualDisplayWhenHeadless: Bool
    let captureRoute: String
    let onSelectDisplay: (UInt32) -> Void
    let onVirtualDisplay: (Bool) -> Void

    var body: some View {
        Section {
            LabeledContent("Capturing") {
                Text(captureRoute)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if displays.count > 1 {
                Picker("Show display", selection: Binding(
                    get: { selectedDisplayID },
                    set: { onSelectDisplay($0) }
                )) {
                    Text("Automatic").tag(UInt32(0))
                    ForEach(displays) { display in
                        Text(display.menuTitle).tag(display.id)
                    }
                }
            } else if let display = displays.first {
                LabeledContent(
                    "Show display",
                    value: selectedDisplayID == 0 ? "Automatic · \(display.menuTitle)" : display.menuTitle
                )
            }
            Toggle(
                "Virtual display when no monitor",
                isOn: Binding(
                    get: { virtualDisplayWhenHeadless },
                    set: { onVirtualDisplay($0) }
                )
            )
        } header: {
            Text("Display")
        } footer: {
            Text("Used when the Mac has no physical display online, so the preview and trackpad still have a screen. An explicit display stays selected even if that display is asleep.")
        }
    }
}

struct HostPermissionsSection: View {
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
                        .accessibilityLabel("Request \(title)")
                }
                Button("Settings", action: onOpenSettings)
                    .accessibilityLabel("Open \(title) in System Settings")
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

struct HostStreamSection: View {
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

struct HostLoginSection: View {
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

extension PreviewQualityMode {
    var menuTitle: String {
        switch self {
        case .balanced: "Balanced"
        case .ultra: "Ultra"
        }
    }
}

extension AudioCaptureSource {
    var menuTitle: String {
        switch self {
        case .off: "Off"
        case .systemOutput: "System"
        case .microphone: "Microphone"
        case .systemAndMicrophone: "System and Microphone"
        }
    }
}
