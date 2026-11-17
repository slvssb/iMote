import SwiftUI

struct PhoneSettingsView: View {
    @ObservedObject var viewModel: IOSKeyboardViewModel
    let showsSessionActions: Bool
    let onDisconnect: @MainActor () -> Void
    let onForgetAndDisconnect: @MainActor () -> Void
    let dismissTypingCapture: @MainActor () -> Void

    @AppStorage("preview.zoom.level") private var previewZoomLevel: Double = 2.5
    @AppStorage("preview.quality.mode") private var previewQualityModeRaw: String = PreviewQualityMode.ultra.rawValue
    @AppStorage("audio.capture.source") private var audioCaptureSourceRaw: String = AudioCaptureSource.off.rawValue
    @AppStorage("preview.virtual.overscan.enabled") private var isVirtualOverscanEnabled = false
    @AppStorage("layout.immersive.landscape.enabled") private var isImmersiveLandscapeModeEnabled = false
    @AppStorage("input.eye.cursor.enabled") private var isEyeCursorEnabled = false
    @AppStorage("feature.eye.cursor.experimental.enabled") private var isEyeCursorExperimentalEnabled = false
    var body: some View {
        Form {
            displaySection
            previewSection
            inputSection
            audioSection
            permissionsSection
            if showsSessionActions {
                sessionSection
            }
            aboutSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var displaySection: some View {
        Section {
            Text(viewModel.screenPreview.hostCaptureStatusLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isPaired {
                if viewModel.screenPreview.displays.count > 1 {
                    Picker("Show display", selection: Binding(
                        get: { viewModel.screenPreview.selectedDisplayID },
                        set: { newValue in
                            dismissTypingCapture()
                            viewModel.selectHostDisplay(newValue)
                        }
                    )) {
                        Text("Automatic").tag(UInt32(0))
                        ForEach(viewModel.screenPreview.displays) { display in
                            Text(display.menuTitle).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                } else if let display = viewModel.screenPreview.displays.first {
                    LabeledContent(
                        "Show display",
                        value: viewModel.screenPreview.selectedDisplayID == 0 ? "Automatic · \(display.menuTitle)" : display.menuTitle
                    )
                }

                Toggle(isOn: Binding(
                    get: { viewModel.screenPreview.virtualDisplayWhenHeadless },
                    set: { newValue in
                        dismissTypingCapture()
                        viewModel.setVirtualDisplayWhenHeadless(newValue)
                    }
                )) {
                    Text("Virtual display when no monitor")
                }
            } else {
                Text("Connect from Devices to choose a display.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Display")
        } footer: {
            Text("Used when the Mac has no physical display online, so the preview and trackpad still have a screen.")
        }
    }

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom level")
                    Spacer()
                    Text("\(previewZoomLevel, specifier: "%.1f")x")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.body)
                Slider(
                    value: Binding(
                        get: { previewZoomLevel },
                        set: { newValue in
                            dismissTypingCapture()
                            previewZoomLevel = clampedZoom(newValue)
                        }
                    ),
                    in: 1.0...3.0,
                    step: 0.5
                ) {
                    Text("Zoom level")
                } minimumValueLabel: {
                    Text("1.0x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("3.0x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } onEditingChanged: { _ in }
                .accessibilityValue("\(previewZoomLevel, specifier: "%.1f") times")
            }

            Toggle("Immersive landscape preview", isOn: $isImmersiveLandscapeModeEnabled)
            Toggle("Virtual overscan", isOn: $isVirtualOverscanEnabled)

            Picker("Preview Quality", selection: Binding(
                get: { viewModel.previewQualityMode },
                set: { newValue in
                    dismissTypingCapture()
                    previewQualityModeRaw = newValue.rawValue
                    viewModel.setPreviewQualityMode(newValue)
                }
            )) {
                Text("Balanced").tag(PreviewQualityMode.balanced)
                Text("Ultra").tag(PreviewQualityMode.ultra)
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isThermalQualityOverrideActive)

            if viewModel.isThermalQualityOverrideActive {
                Text("The Mac is warm, so preview stays on Balanced until it cools down.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Preview")
        }
    }

    private var inputSection: some View {
        Section {
            Toggle("Experimental", isOn: $isEyeCursorExperimentalEnabled)
            if isEyeCursorExperimentalEnabled {
                Toggle("Eye cursor control", isOn: $isEyeCursorEnabled)
                Text("Experimental. Uses front camera to map eye movement to cursor.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Input")
        }
    }

    private var audioSection: some View {
        Section {
            Picker("Audio Source", selection: Binding(
                get: { viewModel.audioCaptureSource },
                set: { newValue in
                    dismissTypingCapture()
                    audioCaptureSourceRaw = newValue.rawValue
                    viewModel.setAudioCaptureSource(newValue)
                }
            )) {
                Text("Off").tag(AudioCaptureSource.off)
                Text("System").tag(AudioCaptureSource.systemOutput)
                Text("Mic").tag(AudioCaptureSource.microphone)
                Text("Both").tag(AudioCaptureSource.systemAndMicrophone)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Audio")
        }
    }

    private var permissionsSection: some View {
        Section {
            if viewModel.isPaired {
                PhoneHostPermissionList(viewModel: viewModel)
                if viewModel.hostPermissionState.allGranted == false {
                    Button("I've given access. Refresh status") {
                        viewModel.refreshHostPermissionStatus()
                    }
                }
            } else {
                Label("Connect from Devices to check the Mac.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Accessibility lets the iPhone type and move the pointer. Screen Recording is only needed for live preview.")
        }
    }

    private var sessionSection: some View {
        Section {
            Button("Disconnect", role: .destructive, action: onDisconnect)
            Button("Forget and Disconnect", role: .destructive, action: onForgetAndDisconnect)
        } footer: {
            Text("Forget tells the Mac to drop this iPhone and deletes its pinned signing key.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: versionText)
            Text("This iPhone \(viewModel.localSigningFingerprint)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("iMote controls your Mac from this iPhone. Pairing uses a one-time code, then this iPhone remembers the Mac's signing key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("About")
        }
    }

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func clampedZoom(_ value: Double) -> Double {
        min(3.0, max(1.0, value))
    }
}
