import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
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
        static let mouseMotionMultiplier: Double = 1.45
        static let scrollMultiplier: Double = 1.2
        static let previewCornerRadius: CGFloat = 10
        static let previewTopGlowHeight: CGFloat = 160
    }

private struct FixedScreenPreview: View {
    @ObservedObject var preview: ScreenPreviewState
    let zoomScale: CGFloat
    let isAutoFollowEnabled: Bool
    let isVirtualOverscanEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let safeZoom = max(zoomScale, 1)
            let overscanX = (isAutoFollowEnabled && isVirtualOverscanEnabled) ? proxy.size.width / (4 * safeZoom) : 0
            let overscanY = (isAutoFollowEnabled && isVirtualOverscanEnabled) ? proxy.size.height / (4 * safeZoom) : 0

            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(.black.opacity(0.8))

                SampleBufferPreviewView(bridge: preview.displayBridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Virtual overscan lets edge content move closer to center at high zoom.
                    .padding(.horizontal, overscanX)
                    .padding(.vertical, overscanY)
                    .scaleEffect(
                        isAutoFollowEnabled ? zoomScale : 1,
                        anchor: isAutoFollowEnabled ? preview.followAnchor : .center
                    )
                    .clipped()

                if preview.hasFrame == false {
                    Color.black.opacity(0.9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(preview.sourceAspectRatio, contentMode: .fit)
    }
}

private struct SampleBufferPreviewView: UIViewRepresentable {
    let bridge: SampleBufferDisplayBridge

    func makeUIView(context: Context) -> SampleBufferDisplayLayerView {
        let view = SampleBufferDisplayLayerView()
        bridge.attach(layer: view.sampleBufferLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayLayerView, context: Context) {
        bridge.attach(layer: uiView.sampleBufferLayer)
    }
}

private final class SampleBufferDisplayLayerView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        guard let layer = self.layer as? AVSampleBufferDisplayLayer else {
            fatalError("Expected AVSampleBufferDisplayLayer backing layer")
        }
        return layer
    }
}

private struct PreviewStatsStripView: View {
    @ObservedObject var preview: ScreenPreviewState
    let onSettingsTapped: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Spacer(minLength: 0)
                Text(preview.statsLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                Spacer(minLength: 0)
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: onSettingsTapped) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 32, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

private struct MacStartupOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 20) {
                Image(systemName: "applelogo")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 148, height: 4)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 148 * progress, height: 4)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

    private enum Field: Hashable {
        case pairingCode
    }

    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var viewModel: IOSKeyboardViewModel
    @AppStorage("preview.zoom.level") private var previewZoomLevel: Double = 2.5
    @AppStorage("preview.quality.mode") private var previewQualityModeRaw: String = PreviewQualityMode.ultra.rawValue
    @AppStorage("preview.virtual.overscan.enabled") private var isVirtualOverscanEnabled = false
    @State private var isTypingCaptureActive = false
    @State private var isZoomSliderEditing = false
    @State private var isConfigSheetPresented = false
    @State private var isStartupOverlayVisible = false
    @State private var startupProgress = 0.0
    @State private var hasSatisfiedStartupMinimum = false
    @State private var startupTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if viewModel.isConnected {
                    GeometryReader { geometry in
                        let topInset = geometry.safeAreaInsets.top
                        let previewAspect = max(viewModel.screenPreview.sourceAspectRatio, 0.01)
                        let previewHeight = geometry.size.width / previewAspect

                        VStack(spacing: 0) {
                            ZStack(alignment: .top) {
                                previewTopGlow(topInset: topInset)

                                fixedScreenPreview
                                    .opacity(isStartupOverlayVisible ? 0 : 1)
                                    .animation(.easeInOut(duration: 0.35), value: isStartupOverlayVisible)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: Layout.previewCornerRadius,
                                            style: .continuous
                                        )
                                    )
                                    .overlay {
                                        RoundedRectangle(
                                            cornerRadius: Layout.previewCornerRadius,
                                            style: .continuous
                                        )
                                        .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                                    }

                                if isStartupOverlayVisible {
                                    MacStartupOverlay(progress: startupProgress)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: Layout.previewCornerRadius,
                                                style: .continuous
                                            )
                                        )
                                        .transition(.opacity)
                                }
                            }
                            .frame(height: previewHeight + topInset)
                            .padding(.top, -topInset)

                            previewStatsStrip
                                .padding(.top, 10)
                                .padding(.bottom, 10)

                            VStack(spacing: Layout.sectionSpacing) {
                                inputPanel
                                mousePanel
                                    .frame(minHeight: Layout.touchpadHeight)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(maxWidth: Layout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.horizontal, Layout.contentPadding)
                            .padding(.bottom, Layout.verticalPadding)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .ignoresSafeArea(edges: .top)
                } else {
                    VStack(spacing: Layout.sectionSpacing) {
                        connectionPanel
                    }
                    .frame(maxWidth: Layout.contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, Layout.contentPadding)
                    .padding(.vertical, Layout.verticalPadding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            previewZoomLevel = clampedZoom(previewZoomLevel)
            viewModel.setPreviewZoomLevel(previewZoomLevel)
            if let storedQuality = PreviewQualityMode(rawValue: previewQualityModeRaw) {
                viewModel.setPreviewQualityMode(storedQuality)
            }
            if viewModel.isConnected {
                beginStartupSequence()
            }
        }
        .onChange(of: previewZoomLevel) { _, newValue in
            viewModel.setPreviewZoomLevel(newValue)
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if isConnected {
                beginStartupSequence()
            } else {
                resetStartupSequence()
            }
        }
        .onChange(of: viewModel.screenPreview.hasFrame) { _, _ in
            dismissStartupOverlayIfReady()
        }
        .sheet(isPresented: $isConfigSheetPresented) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: Layout.sectionSpacing) {
                        previewControlsPanel
                        Button("Disconnect") {
                            viewModel.disconnect()
                            isConfigSheetPresented = false
                        }
                        .buttonStyle(LiquidGlassButtonStyle(tint: .gray))
                        .frame(maxWidth: .infinity)
                    }
                    .padding(Layout.contentPadding)
                }
                .navigationTitle("App Settings")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .ignoresSafeArea(.keyboard, edges: .all)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Disconnected")
                        .font(.title2.weight(.bold))
                }
                Text("iMote: control your Mac from your iPhone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Choose your Mac host and enter the 6-digit pairing code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Layout.statusSpacing) {
                Text(viewModel.connectionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.isDisconnected ? Color.secondary : Color.orange)

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

            VStack(alignment: .leading, spacing: Layout.groupSpacing) {
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
                        .disabled(viewModel.services.isEmpty)
                    }
                    if viewModel.services.isEmpty {
                        Text("No Mac discovered yet. Keep the macOS app open on the same Wi-Fi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.isTrustedAutoReconnect == false {
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
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.green)
                        Text("Trusted device detected. Pairing code is not required.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Layout.fieldHorizontalPadding)
                    .padding(.vertical, Layout.fieldVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
                }
            }

            Button(connectButtonTitle) {
                viewModel.connect()
            }
            .buttonStyle(LiquidGlassButtonStyle(tint: .blue))
            .frame(maxWidth: .infinity)
            .disabled(canConnect == false)

            if canConnect == false {
                Text(connectDisabledReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.hasTrustedSessionLocally {
                HStack(spacing: 12) {
                    Text("Trusted session saved on iPhone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Forget") {
                        viewModel.forgetTrustedSessionOnPhone()
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, Layout.fieldHorizontalPadding)
                .padding(.vertical, Layout.fieldVerticalPadding)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fixedScreenPreview: some View {
        FixedScreenPreview(
            preview: viewModel.screenPreview,
            zoomScale: CGFloat(previewZoomLevel),
            isAutoFollowEnabled: previewZoomLevel > 1.0,
            isVirtualOverscanEnabled: isVirtualOverscanEnabled
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedField = nil
                dismissTypingCapture()
            }
        )
    }

    private func previewTopGlow(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    viewModel.screenPreview.previewGlowColor.opacity(0.48),
                    viewModel.screenPreview.previewGlowColor.opacity(0.24),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Layout.previewTopGlowHeight + topInset)
            .blur(radius: 28)

            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    private func beginStartupSequence() {
        startupTask?.cancel()
        hasSatisfiedStartupMinimum = false
        startupProgress = 0
        withAnimation(.easeOut(duration: 0.12)) {
            isStartupOverlayVisible = true
        }
        withAnimation(.linear(duration: 2.0)) {
            startupProgress = 1
        }

        startupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard Task.isCancelled == false else { return }
            hasSatisfiedStartupMinimum = true
            dismissStartupOverlayIfReady()
        }
    }

    private func dismissStartupOverlayIfReady() {
        guard hasSatisfiedStartupMinimum, viewModel.screenPreview.hasFrame else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            isStartupOverlayVisible = false
        }
    }

    private func resetStartupSequence() {
        startupTask?.cancel()
        startupTask = nil
        hasSatisfiedStartupMinimum = false
        startupProgress = 0
        isStartupOverlayVisible = false
    }

    private var previewStatsStrip: some View {
        PreviewStatsStripView(preview: viewModel.screenPreview) {
            focusedField = nil
            dismissTypingCapture()
            isConfigSheetPresented = true
        }
    }

    private var previewControlsPanel: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Zoom level")
                        .font(.footnote.weight(.semibold))
                    Text("\(previewZoomLevel, specifier: "%.1f")x")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("3.0x")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } onEditingChanged: { editing in
                    isZoomSliderEditing = editing
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Preview quality")
                    .font(.footnote.weight(.semibold))

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))

            HStack(spacing: 12) {
                Text("Virtual overscan")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 0)
                Toggle("", isOn: $isVirtualOverscanEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedField = nil
                dismissTypingCapture()
            }
        )
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: Layout.panelSpacing) {
            panelHeader(
                title: "Keyboard Stream",
                badge: isTypingCaptureActive ? "Focused" : "Idle"
            )

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.16, green: 0.16, blue: 0.17))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.18), lineWidth: 0.8)
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

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mousePanel: some View {
        VStack(alignment: .leading, spacing: Layout.panelSpacing) {
            panelHeader(title: "Trackpad")

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.22, green: 0.22, blue: 0.24) : Color(red: 0.74, green: 0.75, blue: 0.77))

                TrackpadSurfaceView(
                    mouseScale: Layout.mouseMotionMultiplier,
                    scrollScale: Layout.scrollMultiplier,
                    isNaturalScrollingEnabled: false,
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
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.35), lineWidth: 1.2)
                    .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .frame(minHeight: 160)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedField = nil
                dismissTypingCapture()
            }
        )
    }

    private func panelHeader(title: String, badge: String? = nil) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule(style: .continuous))
            }
        }
    }

    private func fieldShell<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        inner()
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
    }

    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.09, blue: 0.10),
                Color(red: 0.11, green: 0.12, blue: 0.14),
                Color(red: 0.06, green: 0.07, blue: 0.08)
            ]
        }

        return [
            Color(red: 0.90, green: 0.91, blue: 0.92),
            Color(red: 0.84, green: 0.85, blue: 0.87),
            Color(red: 0.78, green: 0.79, blue: 0.81)
        ]
    }

    private func clampedZoom(_ value: Double) -> Double {
        min(3.0, max(1.0, value))
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

    private var connectButtonTitle: String {
        viewModel.isConnecting ? "Connecting…" : "Connect to Mac"
    }

    private var canConnect: Bool {
        if viewModel.isConnecting {
            return false
        }
        guard viewModel.selectedService != nil else {
            return false
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
        if viewModel.selectedService == nil {
            return "Select a Mac host to continue."
        }
        if viewModel.isTrustedAutoReconnect == false && viewModel.pairingCode.count != 6 {
            return "Enter the 6-digit pairing code."
        }
        return ""
    }
}
