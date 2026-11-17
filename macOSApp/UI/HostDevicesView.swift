import SwiftUI

struct HostDevicesView: View {
    @ObservedObject var appState: MacAppState

    var body: some View {
        Form {
            HostConnectedDevicesSection(phones: appState.connectedPhones)
            HostTrustedDevicesSection(
                devices: appState.trustedDevices,
                onRemove: { appState.removeTrustedDevice(id: $0) },
                onClear: { appState.clearTrustedDevices() }
            )
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
    }
}

struct HostConnectedDevicesSection: View {
    let phones: [ConnectedPhone]

    var body: some View {
        Section {
            if phones.isEmpty {
                ContentUnavailableView(
                    "No iPhone connected",
                    systemImage: "iphone.slash",
                    description: { Text("No active client") }
                )
            } else {
                ForEach(phones) { phone in
                    LabeledContent(phone.name) {
                        Text(phone.isPaired ? "Paired" : "Connecting")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(phone.name), \(phone.isPaired ? "paired" : "connecting")")
                }
            }
        } header: {
            Text("Connected iPhones")
        }
    }
}

struct HostTrustedDevicesSection: View {
    let devices: [TrustedDeviceRecord]
    let onRemove: (String) -> Void
    let onClear: () -> Void
    @State private var isClearConfirmationPresented = false

    var body: some View {
        Section {
            if devices.isEmpty {
                ContentUnavailableView(
                    "No trusted iPhones",
                    systemImage: "checkmark.shield",
                    description: { Text("No trusted devices") }
                )
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
                        .accessibilityLabel("Remove \(device.displayName)")
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
