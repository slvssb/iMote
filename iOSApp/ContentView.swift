import SwiftUI

struct ContentView: View {
    private enum PreviewZoomLevel: String, CaseIterable, Identifiable {
        case x15 = "1.5x"
        case x20 = "2.0x"
        case x25 = "2.5x"

        var id: String { rawValue }

        var scale: CGFloat {
            switch self {
            case .x15: return 1.5
            case .x20: return 2.0
            case .x25: return 2.5
            }
        }
    }

    private enum Layout {
        static let sectionSpacing: CGFloat = 16
        static let panelSpacing: CGFloat = 14
        static let contentPadding: CGFloat = 18
        static let verticalPadding: CGFloat = 16
        static let contentMaxWidth: CGFloat = 620
        static let controlSpacing: CGFloat = 10
        static let fieldCornerRadius: CGFloat = 12
        static let groupSpacing: CGFloat = 12
        static let rowSpacing: CGFloat = 8
        static let fieldHorizontalPadding: CGFloat = 12
        static let fieldVerticalPadding: CGFloat = 10
        static let statusSpacing: CGFloat = 4
        static let touchpadHeight: CGFloat = 210
        static let screenPreviewHeight: CGFloat = 236
        static let mouseMotionMultiplier: Double = 1.45
        static let scrollMultiplier: Double = 1.2
    }

private struct FixedScreenPreview: View {
    @ObservedObject var preview: ScreenPreviewState
    let height: CGFloat
    let zoomScale: CGFloat
    let isAutoFollowEnabled: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.black.opacity(0.8))

            if let previewImage = preview.frameImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(
                        isAutoFollowEnabled ? zoomScale : 1,
                        anchor: isAutoFollowEnabled ? preview.followAnchor : .center
                    )
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "display.2")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Waiting for screen frames...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

    private enum Field: Hashable {
        case pairingCode
    }

    @ObservedObject var viewModel: IOSKeyboardViewModel
    @State private var isTypingCaptureActive = false
    @State private var isNaturalScrollingEnabled = true
    @State private var isAutoFollowEnabled = true
    @State private var previewZoomLevel: PreviewZoomLevel = .x20
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.34, blue: 0.56).opacity(0.23),
                    Color(red: 0.24, green: 0.48, blue: 0.66).opacity(0.17),
                    Color(red: 0.25, green: 0.30, blue: 0.48).opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if viewModel.isConnected {
                    fixedScreenPreview
                        .zIndex(1)
                }

                ScrollView {
                    VStack(spacing: Layout.sectionSpacing) {
                        if viewModel.isConnected {
                            previewDebugStrip
                            inputPanel
                            mousePanel
                        } else {
                            connectionPanel
                        }
                    }
                    .frame(maxWidth: Layout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Layout.contentPadding)
                    .padding(.vertical, Layout.verticalPadding)
                }
                .scrollDismissesKeyboard(.never)
                .scrollDisabled(isTypingCaptureActive)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .clipped()
                .zIndex(0)
                .onTapGesture {
                    focusedField = nil
                    dismissTypingCapture()
                }
            }
        }
    }

    private var connectionPanel: some View {
        LiquidGlassPanel {
            VStack(alignment: .leading, spacing: Layout.panelSpacing) {
                panelHeader(
                    title: "Remote Keyboard",
                    subtitle: "Select your Mac and pair once to start streaming.",
                    badge: connectionBadgeText
                )

                VStack(alignment: .leading, spacing: Layout.groupSpacing) {
                    if viewModel.isDisconnected {
                        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                            Text("Mac Host")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            fieldShell {
                                Picker("Mac Host", selection: selectedServiceBinding) {
                                    ForEach(viewModel.services) { service in
                                        Text("\(service.name) (\(service.host))")
                                            .tag(Optional(service))
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }

                    if viewModel.isPaired == false {
                        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                            Text("Pairing Code")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            fieldShell {
                                TextField("123456", text: $viewModel.pairingCode)
                                    .focused($focusedField, equals: .pairingCode)
                                    .keyboardType(.numberPad)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onTapGesture {
                                        isTypingCaptureActive = false
                                    }
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }

                HStack(spacing: Layout.controlSpacing) {
                    if viewModel.isPaired {
                        Button("Disconnect") {
                            viewModel.disconnect()
                        }
                        .buttonStyle(LiquidGlassButtonStyle(tint: .gray))
                        .frame(maxWidth: .infinity)
                    } else {
                        Button("Connect") {
                            viewModel.connect()
                        }
                        .buttonStyle(LiquidGlassButtonStyle(tint: .blue))
                        .frame(maxWidth: .infinity)

                        Button("Disconnect") {
                            viewModel.disconnect()
                        }
                        .buttonStyle(LiquidGlassButtonStyle(tint: .gray))
                        .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: Layout.statusSpacing) {
                    Text(viewModel.connectionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.isPaired ? Color.green : Color.secondary)

                    if let error = viewModel.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, Layout.fieldHorizontalPadding)
                .padding(.vertical, Layout.fieldVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
            }
        }
    }

    private var fixedScreenPreview: some View {
        FixedScreenPreview(
            preview: viewModel.screenPreview,
            height: Layout.screenPreviewHeight,
            zoomScale: previewZoomLevel.scale,
            isAutoFollowEnabled: isAutoFollowEnabled
        )
    }

    private var previewDebugStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Preview")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Preview Quality", selection: Binding(
                    get: { viewModel.previewQualityMode },
                    set: { viewModel.setPreviewQualityMode($0) }
                )) {
                    Text("Balanced").tag(PreviewQualityMode.balanced)
                    Text("Ultra").tag(PreviewQualityMode.ultra)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Auto-follow cursor", isOn: $isAutoFollowEnabled)
                .toggleStyle(.switch)
                .font(.footnote.weight(.semibold))

            if isAutoFollowEnabled {
                HStack(spacing: 10) {
                    Text("Zoom")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Picker("Zoom Strength", selection: $previewZoomLevel) {
                        ForEach(PreviewZoomLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Text(viewModel.screenPreview.statsLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var inputPanel: some View {
        LiquidGlassPanel {
            VStack(alignment: .leading, spacing: Layout.panelSpacing) {
                panelHeader(
                    title: "Keyboard Stream",
                    subtitle: "Tap to focus. Toolbar modifiers and special keys remain active.",
                    badge: isTypingCaptureActive ? "Focused" : "Idle"
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                        }
                    HiddenTextInputView(
                        isActive: isTypingCaptureActive,
                        activeModifiers: viewModel.activeModifiers,
                        onCharacter: { character in
                            viewModel.handleCharacter(character)
                        },
                        onBackspace: {
                            viewModel.handleBackspace()
                        },
                        onReturn: {
                            viewModel.handleReturn()
                        },
                        onToggleModifier: { modifier in
                            viewModel.toggleModifier(modifier)
                        },
                        onSpecialKey: { key in
                            viewModel.sendNamedKey(key)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(height: 128)
                .highPriorityGesture(
                    TapGesture().onEnded {
                        focusedField = nil
                        isTypingCaptureActive = true
                    }
                )

                Text("Tap the stream field to type. Input sends incrementally and clears after 3 seconds idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.activeModifiers.isEmpty == false {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Active Modifiers")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.activeModifiers.map(\.rawValue).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule(style: .continuous))
                    }
                }
            }
        }
    }

    private var mousePanel: some View {
        LiquidGlassPanel {
            VStack(alignment: .leading, spacing: Layout.panelSpacing) {
                panelHeader(
                    title: "Mouse Control",
                    subtitle: "1-finger tap: left click, 2-finger tap: right click, 3-finger tap: middle click.",
                    badge: "Trackpad"
                )

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
                        }

                    TrackpadSurfaceView(
                        mouseScale: Layout.mouseMotionMultiplier,
                        scrollScale: Layout.scrollMultiplier,
                        isNaturalScrollingEnabled: isNaturalScrollingEnabled,
                        onMove: { deltaX, deltaY in
                            viewModel.moveMouse(deltaX: deltaX, deltaY: deltaY)
                        },
                        onScroll: { deltaX, deltaY in
                            viewModel.scrollMouse(deltaX: deltaX, deltaY: deltaY)
                        },
                        onClick: { button, action in
                            viewModel.clickMouse(button: button, action: action)
                        }
                    )

                    VStack(spacing: 8) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                        Text("Trackpad Surface")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: Layout.touchpadHeight)

                Toggle("Natural Scrolling", isOn: $isNaturalScrollingEnabled)
                    .toggleStyle(.switch)
                    .font(.footnote.weight(.semibold))

                Text("1-finger drag: move cursor • 2-finger drag: scroll • 3-finger drag: hold and drag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func panelHeader(title: String, subtitle: String, badge: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule(style: .continuous))
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldShell<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        inner()
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
    }

    private func dismissTypingCapture() {
        if isTypingCaptureActive {
            isTypingCaptureActive = false
        }
    }

    private var connectionBadgeText: String {
        if viewModel.isPaired {
            return "Paired"
        }
        if viewModel.isDisconnected {
            return "Disconnected"
        }
        return "Connecting"
    }

    private var selectedServiceBinding: Binding<DiscoveredService?> {
        Binding(
            get: { viewModel.selectedService },
            set: { viewModel.selectedService = $0 }
        )
    }
}

