import SwiftUI
import UIKit

struct PhoneDevicesView: View {
    @ObservedObject var viewModel: IOSKeyboardViewModel
    @FocusState.Binding var focusedField: PhoneFocusField?
    @Binding var isTypingCaptureActive: Bool

    let showConnectedLayout: Bool
    let isDisconnectTransitionActive: Bool
    let onDisconnect: @MainActor () -> Void
    let onForgetAndDisconnect: @MainActor () -> Void
    let onOpenRemote: @MainActor () -> Void

    var body: some View {
        List {
            if viewModel.shouldShowPermissionGate {
                permissionGate
            } else if showsSession {
                sessionSection
                fingerprintSection
                trustedSection
            } else {
                introSection
                connectionSection
                if viewModel.connectionTargetMode == .localDiscovery {
                    discoveredSection
                } else {
                    savedHostSection
                    manualAddressSection
                }
                pairingSection
                fingerprintSection
                if viewModel.hasTrustedSessionLocally {
                    forgetCurrentSection
                }
                connectSection
                trustedSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private var showsSession: Bool {
        viewModel.isPaired || showConnectedLayout || isDisconnectTransitionActive
    }

    private var introSection: some View {
        Section {
            VStack(spacing: 12) {
                if let appIcon = primaryAppIconImage {
                    Image(uiImage: appIcon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "iphone.gen3")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 72, height: 72)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                }

                Text("Control your Mac from your iPhone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("End-to-end encrypted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var sessionSection: some View {
        Section {
            LabeledContent("Status", value: viewModel.connectionLabel)
            if showConnectedLayout {
                Button("Open Remote", action: onOpenRemote)
                Button("Disconnect", role: .destructive, action: onDisconnect)
                Button("Forget and Disconnect", role: .destructive, action: onForgetAndDisconnect)
            } else if isDisconnectTransitionActive {
                Text("Disconnecting…")
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.connectionLabel)
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel.lastError, error.isEmpty == false {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("Forget tells the Mac to drop this iPhone and deletes its pinned signing key.")
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Status", value: viewModel.connectionLabel)
            Picker("Connection Mode", selection: $viewModel.connectionTargetMode) {
                Text("Local").tag(IOSKeyboardViewModel.ConnectionTargetMode.localDiscovery)
                Text("Remote").tag(IOSKeyboardViewModel.ConnectionTargetMode.manualAddress)
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.connectionTargetMode) { _, _ in
                viewModel.noteConnectionDraftChanged()
            }
        } header: {
            Text("Connection")
        } footer: {
            if viewModel.connectionTargetMode == .manualAddress {
                Text("Use the Tailscale name or 100.x address shown on the Mac. Saved hosts stay on this iPhone.")
            }
        }
    }

    private var discoveredSection: some View {
        Section {
            if viewModel.services.isEmpty {
                ContentUnavailableView(
                    "No Macs nearby",
                    systemImage: "wifi.slash",
                    description: Text("No Mac discovered yet. Keep the macOS app open on the same Wi-Fi network.")
                )
            } else {
                Picker("Mac Host", selection: selectedServiceBinding) {
                    ForEach(viewModel.services) { service in
                        Text("\(service.name) (\(service.host))")
                            .tag(Optional(service))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Mac Host")
            }
        } header: {
            Text("Discovered")
        }
    }

    private var savedHostSection: some View {
        Section {
            if viewModel.savedHosts.isEmpty {
                Label("No saved hosts yet", systemImage: "externaldrive.badge.plus")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.savedHosts) { saved in
                    HStack(spacing: 10) {
                        Button {
                            viewModel.selectSavedHost(saved)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.host)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Port \(saved.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(saved.host) port \(saved.port)")
                        if viewModel.manualHost.caseInsensitiveCompare(saved.host) == .orderedSame,
                           viewModel.manualPortText == String(saved.port) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Selected")
                        }
                        Button {
                            viewModel.forgetSavedHost(saved)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(saved.host)")
                    }
                }
            }
        } header: {
            Text("Saved Hosts")
        } footer: {
            Text("Saved hosts are addresses on this iPhone, not credentials.")
        }
    }

    private var manualAddressSection: some View {
        Section {
            TextField("macbook.tailnet.ts.net", text: $viewModel.manualHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel("Tailscale name or IP")
                .onChange(of: viewModel.manualHost) { _, _ in
                    viewModel.noteConnectionDraftChanged()
                }
            TextField("8989", text: $viewModel.manualPortText)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Port")
                .onChange(of: viewModel.manualPortText) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    let trimmed = String(digitsOnly.prefix(5))
                    if viewModel.manualPortText != trimmed {
                        viewModel.manualPortText = trimmed
                    }
                    viewModel.noteConnectionDraftChanged()
                }
        } header: {
            Text("Tailscale name or IP")
        }
    }

    private var pairingSection: some View {
        Section {
            if viewModel.isTrustedAutoReconnect == false {
                TextField("123456", text: $viewModel.pairingCode)
                    .focused($focusedField, equals: .pairingCode)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityLabel("Pairing code")
                    .onChange(of: viewModel.pairingCode) { _, newValue in
                        let digitsOnly = newValue.filter(\.isNumber)
                        let trimmed = String(digitsOnly.prefix(6))
                        if viewModel.pairingCode != trimmed {
                            viewModel.pairingCode = trimmed
                        }
                    }
                    .onTapGesture {
                        isTypingCaptureActive = false
                    }
            } else {
                Label("Trusted device detected. Pairing code is not required.", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(viewModel.isTrustedAutoReconnect ? "Trust" : "Pairing Code")
        }
    }

    private var fingerprintSection: some View {
        Section {
            Text("This iPhone \(viewModel.localSigningFingerprint)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let macFingerprint = viewModel.pairedHostFingerprint {
                Text("Mac \(macFingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if viewModel.pairedHostFingerprintIsNew {
                    Text("First pair. Compare these fingerprints with the Mac before you type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Signing keys")
        }
    }

    private var forgetCurrentSection: some View {
        Section {
            Button("Forget trusted Mac") {
                viewModel.forgetTrustedSessionOnPhone()
            }
            .foregroundStyle(.red)
        }
    }

    private var connectSection: some View {
        Section {
            Button(connectButtonTitle) {
                viewModel.connect()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .center)
            .disabled(canConnect == false)
            .accessibilityHint(canConnect ? "Pair with the selected Mac" : connectDisabledReason)

            if let error = viewModel.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if canConnect == false, shouldShowConnectDisabledReason {
                Text(connectDisabledReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var trustedSection: some View {
        Section {
            if viewModel.trustedHostRecords.isEmpty {
                ContentUnavailableView(
                    "No trusted Macs",
                    systemImage: "checkmark.shield",
                    description: Text("After you pair, this iPhone remembers that Mac by its signing key.")
                )
            } else {
                ForEach(viewModel.trustedHostRecords) { record in
                    let fingerprint = TrustedHostPresentation.fingerprint(for: record)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fingerprint)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        ForEach(Array(TrustedHostPresentation.endpointLines(for: record).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button("Forget", role: .destructive) {
                            viewModel.forgetTrustedHost(endpointKeys: record.endpoints)
                        }
                        .accessibilityLabel("Forget trusted Mac \(fingerprint)")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        } header: {
            Text("Trusted Macs")
        } footer: {
            Text("Trust is the Mac's signing key. A trusted Mac reconnects without a new pairing code. Forget deletes that key on this iPhone.")
        }
    }

    private var permissionGate: some View {
        Section {
            Text("Accessibility lets the iPhone type and move the pointer. Screen Recording is only needed for live preview.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            PhoneHostPermissionList(viewModel: viewModel)
            if viewModel.hostPermissionState.allGranted == false {
                Button("I've given access. Refresh status") {
                    viewModel.refreshHostPermissionStatus()
                }
            }
            if viewModel.canContinueAfterPermissionGate {
                Button("Continue") {
                    viewModel.completePermissionGate()
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Host Permissions")
        }
    }

    private var primaryAppIconImage: UIImage? {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let iconFiles = primary["CFBundleIconFiles"] as? [String],
            let iconName = iconFiles.last,
            let image = UIImage(named: iconName)
        else {
            return nil
        }
        return image
    }

    private var selectedServiceBinding: Binding<DiscoveredService?> {
        Binding(
            get: { viewModel.selectedService },
            set: { viewModel.selectedService = $0 }
        )
    }

    private var connectButtonTitle: String {
        viewModel.isConnecting ? "Connecting…" : "Connect to Mac"
    }

    private var canConnect: Bool {
        if viewModel.isConnecting {
            return false
        }
        switch viewModel.connectionTargetMode {
        case .localDiscovery:
            guard viewModel.selectedService != nil else {
                return false
            }
        case .manualAddress:
            guard case .success = RemoteHostAddress.parse(hostField: viewModel.manualHost, portField: viewModel.manualPortText) else {
                return false
            }
        }
        if viewModel.isTrustedAutoReconnect {
            return true
        }
        return viewModel.pairingCode.count == 6
    }

    private var connectDisabledReason: String {
        if viewModel.isConnecting {
            return "Connecting to your Mac..."
        }
        if viewModel.connectionTargetMode == .localDiscovery, viewModel.selectedService == nil {
            return "Select a Mac host to continue."
        }
        if viewModel.connectionTargetMode == .manualAddress {
            if case let .failure(failure) = RemoteHostAddress.parse(hostField: viewModel.manualHost, portField: viewModel.manualPortText) {
                return failure.message
            }
        }
        if viewModel.isTrustedAutoReconnect == false && viewModel.pairingCode.count != 6 {
            return "Enter the 6-digit pairing code."
        }
        return ""
    }

    private var shouldShowConnectDisabledReason: Bool {
        if viewModel.connectionTargetMode == .manualAddress,
           connectDisabledReason == RemoteHostAddress.ParseFailure.missingHost.message {
            return false
        }
        return connectDisabledReason.isEmpty == false
    }
}
