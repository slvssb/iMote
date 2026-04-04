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
        static let previewCornerRadius: CGFloat = 18
        static let previewTopGlowHeight: CGFloat = 160
        static let previewHorizontalInset: CGFloat = 4
    }

private struct FixedScreenPreview: View {
    @ObservedObject var preview: ScreenPreviewState
    let zoomScale: CGFloat
    let isAutoFollowEnabled: Bool
    let isVirtualOverscanEnabled: Bool
    let videoGravity: AVLayerVideoGravity
    let showsBlackBackdrop: Bool

    var body: some View {
        GeometryReader { proxy in
            let safeZoom = max(zoomScale, 1)
            let overscanX = (isAutoFollowEnabled && isVirtualOverscanEnabled) ? proxy.size.width / (4 * safeZoom) : 0
            let overscanY = (isAutoFollowEnabled && isVirtualOverscanEnabled) ? proxy.size.height / (4 * safeZoom) : 0

            ZStack(alignment: .bottomLeading) {
                if showsBlackBackdrop {
                    Rectangle()
                        .fill(.black.opacity(0.8))
                }

                SampleBufferPreviewView(bridge: preview.displayBridge, videoGravity: videoGravity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Virtual overscan lets edge content move closer to center at high zoom.
                    .padding(.horizontal, overscanX)
                    .padding(.vertical, overscanY)
                    .scaleEffect(
                        isAutoFollowEnabled ? zoomScale : 1,
                        anchor: isAutoFollowEnabled ? preview.followAnchor : .center
                    )
                    .clipped()

                if preview.hasFrame == false && showsBlackBackdrop {
                    Color.black.opacity(0.9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SampleBufferPreviewView: UIViewRepresentable {
    let bridge: SampleBufferDisplayBridge
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> SampleBufferDisplayLayerView {
        let view = SampleBufferDisplayLayerView()
        view.sampleBufferLayer.videoGravity = videoGravity
        bridge.attach(layer: view.sampleBufferLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayLayerView, context: Context) {
        uiView.sampleBufferLayer.videoGravity = videoGravity
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
    var progressOpacity: Double = 1

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
                .opacity(progressOpacity)
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MacCenteredLogoOverlay: View {
    var body: some View {
        ZStack {
            Color.black
            Image(systemName: "applelogo")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

    private enum Field: Hashable {
        case pairingCode
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var viewModel: IOSKeyboardViewModel
    @AppStorage("preview.zoom.level") private var previewZoomLevel: Double = 2.5
    @AppStorage("preview.quality.mode") private var previewQualityModeRaw: String = PreviewQualityMode.ultra.rawValue
    @AppStorage("audio.capture.source") private var audioCaptureSourceRaw: String = AudioCaptureSource.off.rawValue
    @AppStorage("preview.virtual.overscan.enabled") private var isVirtualOverscanEnabled = false
    @AppStorage("layout.immersive.landscape.enabled") private var isImmersiveLandscapeModeEnabled = false
    @AppStorage("input.eye.cursor.enabled") private var isEyeCursorEnabled = false
    @AppStorage("feature.eye.cursor.experimental.enabled") private var isEyeCursorExperimentalEnabled = false
    @State private var isTypingCaptureActive = false
    @State private var isZoomSliderEditing = false
    @State private var isConfigSheetPresented = false
    @State private var isStartupOverlayVisible = false
    @State private var isStartupProgressVisible = false
    @State private var startupProgress = 0.0
    @State private var startupTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var disconnectTask: Task<Void, Never>?
    @State private var isDisconnectPreviewOverlayVisible = false
    @State private var disconnectPreviewOverlayOpacity = 0.0
    @State private var isDisconnectTransitionActive = false
    @State private var connectedScreenOpacity = 1.0
    @State private var connectionScreenOpacity = 1.0
    @State private var showConnectedLayout = false
    @State private var isLivePreviewVisible = false
    @State private var isControlledDisconnectFlow = false
    @State private var shouldForgetOnControlledDisconnect = false
    @State private var lockedDisconnectPreviewAspectRatio: CGFloat?
    @State private var isPreviewSectionVisible = false
    @State private var isStatsSectionVisible = false
    @State private var isKeyboardSectionVisible = false
    @State private var isTrackpadSectionVisible = false
    @State private var previewResyncTask: Task<Void, Never>?
    @State private var lastPreviewResyncAt: Date?
    @State private var previewSurfaceVersion = 0
    @State private var lastOrientationResyncAt: Date?
    @StateObject private var eyeCursorController = EyeCursorController()
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
                if showConnectedLayout || isDisconnectTransitionActive {
                    GeometryReader { geometry in
                        let topInset = resolvedTopInset(geometrySafeAreaTop: geometry.safeAreaInsets.top)
                        let previewAspectSource = lockedDisconnectPreviewAspectRatio ?? viewModel.screenPreview.sourceAspectRatio
                        let previewAspect = max(previewAspectSource, 0.01)
                        let previewWidth = max(geometry.size.width - (Layout.previewHorizontalInset * 2), 1)
                        let previewHeight = previewWidth / previewAspect

                        if isImmersiveLandscapeModeEnabled {
                            ZStack {
                                ZStack {
                                    fixedScreenPreview
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .opacity(isLivePreviewVisible ? 1 : 0)

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
                                            guard isTypingCaptureActive == false else { return }
                                            viewModel.clickMouse(button: button, action: action)
                                        },
                                        onFourFingerSwipe: { direction in
                                            switch direction {
                                            case .up:
                                                viewModel.sendNamedKey(.upArrow, modifiers: [.control])
                                            case .down:
                                                viewModel.sendNamedKey(.downArrow, modifiers: [.control])
                                            case .left:
                                                viewModel.sendNamedKey(.leftArrow, modifiers: [.control])
                                            case .right:
                                                viewModel.sendNamedKey(.rightArrow, modifiers: [.control])
                                            }
                                        },
                                        isVisualChromeEnabled: false
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                    if isStartupOverlayVisible {
                                        MacStartupOverlay(
                                            progress: startupProgress,
                                            progressOpacity: isStartupProgressVisible ? 1 : 0
                                        )
                                    }

                                    if isDisconnectPreviewOverlayVisible {
                                        MacCenteredLogoOverlay()
                                            .opacity(disconnectPreviewOverlayOpacity)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.vertical, 10)

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
                                    onModifierTap: { modifier in
                                        viewModel.sendModifierTap(modifier)
                                    },
                                    onToggleModifier: { modifier in
                                        viewModel.toggleModifier(modifier)
                                    },
                                    onSpecialKey: { key in
                                        viewModel.sendNamedKey(key)
                                    }
                                )
                                .frame(width: 1, height: 1)
                                .opacity(0.01)
                                .allowsHitTesting(false)

                                VStack {
                                    HStack {
                                        Spacer(minLength: 0)
                                        Button {
                                            focusedField = nil
                                            dismissTypingCapture()
                                            isConfigSheetPresented = true
                                        } label: {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.headline.weight(.semibold))
                                                .frame(width: 42, height: 42)
                                                .background(.ultraThinMaterial, in: Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.top, topInset + 8)
                                        .padding(.trailing, 12)
                                    }

                                    Spacer(minLength: 0)

                                    HStack {
                                        Spacer(minLength: 0)
                                        Button {
                                            focusedField = nil
                                            isTypingCaptureActive = true
                                        } label: {
                                            Image(systemName: "keyboard")
                                                .font(.headline.weight(.semibold))
                                                .frame(width: 50, height: 50)
                                                .background(.ultraThinMaterial, in: Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 14)
                                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 12))
                                    }
                                }
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    if isTypingCaptureActive {
                                        dismissTypingCapture()
                                    }
                                }
                            )
                            .opacity(isConnectedContentVisible ? connectedScreenOpacity : 0)
                            .allowsHitTesting(isConnectedContentVisible && connectedScreenOpacity > 0.01)
                        } else {
                            VStack(spacing: 0) {
                                Color.clear
                                    .frame(height: topInset)
                                    .opacity(isPreviewSectionVisible ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.35), value: isPreviewSectionVisible)

                                ZStack {
                                    if isLivePreviewVisible == false || isStartupOverlayVisible || isDisconnectPreviewOverlayVisible {
                                        Color.black
                                    }

                                    fixedScreenPreview
                                        .opacity(isLivePreviewVisible ? 1 : 0)

                                    if isStartupOverlayVisible {
                                        MacStartupOverlay(
                                            progress: startupProgress,
                                            progressOpacity: isStartupProgressVisible ? 1 : 0
                                        )
                                    }

                                    if isDisconnectPreviewOverlayVisible {
                                        MacCenteredLogoOverlay()
                                            .opacity(disconnectPreviewOverlayOpacity)
                                    }
                                }
                                    .opacity(isPreviewSectionVisible ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.35), value: isPreviewSectionVisible)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .frame(height: previewHeight)
                                    .padding(.horizontal, Layout.previewHorizontalInset)
                                    .allowsHitTesting(isPreviewSectionVisible)

                                previewStatsStrip
                                    .padding(.top, 10)
                                    .padding(.bottom, 10)
                                    .opacity(isStatsSectionVisible ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.35), value: isStatsSectionVisible)
                                    .allowsHitTesting(isStatsSectionVisible)

                                inputPanel
                                    .frame(maxWidth: Layout.contentMaxWidth, alignment: .top)
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    .opacity(isKeyboardSectionVisible ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.35), value: isKeyboardSectionVisible)
                                    .allowsHitTesting(isKeyboardSectionVisible)
                                    .padding(.top, Layout.sectionSpacing)
                                    .padding(.horizontal, Layout.contentPadding)

                                mousePanel
                                    .frame(minHeight: Layout.touchpadHeight)
                                    .frame(maxWidth: Layout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .opacity(isTrackpadSectionVisible ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.35), value: isTrackpadSectionVisible)
                                    .allowsHitTesting(isTrackpadSectionVisible)
                                    .padding(.top, Layout.sectionSpacing)
                                .padding(.horizontal, Layout.contentPadding)
                                .padding(.bottom, Layout.verticalPadding)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .opacity(isConnectedContentVisible ? connectedScreenOpacity : 0)
                            .allowsHitTesting(isConnectedContentVisible && connectedScreenOpacity > 0.01)
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    VStack(spacing: Layout.sectionSpacing) {
                        if viewModel.shouldShowPermissionGate {
                            permissionGatePanel
                        } else {
                            connectionPanel
                        }
                    }
                    .frame(maxWidth: Layout.contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, Layout.contentPadding)
                    .padding(.vertical, Layout.verticalPadding)
                    .opacity(connectionScreenOpacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            applyOrientationPolicy()
            previewZoomLevel = clampedZoom(previewZoomLevel)
            viewModel.setPreviewZoomLevel(previewZoomLevel)
            eyeCursorController.onMove = { deltaX, deltaY in
                viewModel.moveMouse(deltaX: deltaX, deltaY: deltaY)
            }
            updateEyeCursorState()
            if let storedQuality = PreviewQualityMode(rawValue: previewQualityModeRaw) {
                viewModel.setPreviewQualityMode(storedQuality)
            }
            if let storedAudioSource = AudioCaptureSource(rawValue: audioCaptureSourceRaw) {
                viewModel.setAudioCaptureSource(storedAudioSource)
            }
            if viewModel.isPaired {
                if viewModel.hasCompletedPermissionGate {
                    beginConnectSequence()
                }
            }
        }
        .onDisappear {
            IMoteOrientationController.setImmersiveModeEnabled(false)
            eyeCursorController.stop()
            stopPreviewResyncMonitor()
        }
        .onChange(of: previewZoomLevel) { _, newValue in
            viewModel.setPreviewZoomLevel(newValue)
        }
        .onChange(of: isEyeCursorEnabled) { _, _ in
            updateEyeCursorState()
        }
        .onChange(of: isEyeCursorExperimentalEnabled) { _, isEnabled in
            if isEnabled == false {
                isEyeCursorEnabled = false
            }
            updateEyeCursorState()
        }
        .onChange(of: isImmersiveLandscapeModeEnabled) { _, isEnabled in
            guard showConnectedLayout || isDisconnectTransitionActive else { return }
            // Keep preview visible when switching layout modes mid-session.
            if isEnabled || viewModel.screenPreview.hasFrame {
                isPreviewSectionVisible = true
                isLivePreviewVisible = true
            }
            forcePreviewPipelineResync(reason: "immersiveToggle")
        }
        .onChange(of: shouldUseImmersiveLandscapeOrientation) { _, _ in
            applyOrientationPolicy()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            applyOrientationPolicy()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            applyOrientationPolicy()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            handleOrientationDidChange()
        }
        .onChange(of: viewModel.isPaired) { wasPaired, isPaired in
            updateEyeCursorState()
            if isPaired {
                cancelDisconnectSequence()
                if viewModel.hasCompletedPermissionGate {
                    beginConnectSequence()
                } else {
                    resetTransitionState()
                }
            } else {
                stopPreviewResyncMonitor()
                if isControlledDisconnectFlow {
                    return
                }
                if wasPaired {
                    beginDisconnectSequence()
                } else {
                    resetTransitionState()
                }
            }
        }
        .onChange(of: viewModel.hasCompletedPermissionGate) { _, completed in
            guard completed, viewModel.isPaired else { return }
            beginConnectSequence()
        }
        .sheet(isPresented: $isConfigSheetPresented) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: Layout.sectionSpacing) {
                        previewControlsPanel
                        Button("Disconnect", role: .destructive) {
                            beginControlledDisconnectSequence(forgetDevice: false)
                            isConfigSheetPresented = false
                        }
                        .buttonStyle(LiquidGlassButtonStyle(tint: .red))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)

                        Button("Forget and Disconnect", role: .destructive) {
                            beginControlledDisconnectSequence(forgetDevice: true)
                            isConfigSheetPresented = false
                        }
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
            VStack(alignment: .center, spacing: 12) {
                if let appIcon = primaryAppIconImage {
                    Image(uiImage: appIcon)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 72, height: 72)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Text("Control your Mac from your iPhone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("End-to-end encrypted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: Layout.groupSpacing) {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    Text("Connection Mode")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Connection Mode", selection: $viewModel.connectionTargetMode) {
                        Text("Local").tag(IOSKeyboardViewModel.ConnectionTargetMode.localDiscovery)
                        Text("Remote").tag(IOSKeyboardViewModel.ConnectionTargetMode.manualAddress)
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                        Text("Mac Host")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if viewModel.connectionTargetMode == .manualAddress {
                            Text("Remote mode requires the Mac host to be reachable at this IP and port.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, viewModel.connectionTargetMode == .manualAddress ? 12 : 0)
                    if viewModel.connectionTargetMode == .localDiscovery {
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
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                            Text("Remote Host / IP")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            fieldShell {
                                TextField("203.0.113.10", text: $viewModel.manualHost)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Text("Port")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            fieldShell {
                                TextField("8989", text: $viewModel.manualPortText)
                                    .keyboardType(.numberPad)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: viewModel.manualPortText) { _, newValue in
                                        let digitsOnly = newValue.filter(\.isNumber)
                                        let trimmed = String(digitsOnly.prefix(5))
                                        if viewModel.manualPortText != trimmed {
                                            viewModel.manualPortText = trimmed
                                        }
                                    }
                            }
                        }
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
                } else if viewModel.connectionTargetMode == .localDiscovery {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.green)
                        Text("Trusted device detected. Pairing code is not required.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.top, 64)

            Button(connectButtonTitle) {
                viewModel.connect()
            }
            .buttonStyle(LiquidGlassButtonStyle(tint: .blue))
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .disabled(canConnect == false)

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if canConnect == false,
                      shouldShowConnectDisabledReason {
                Text(connectDisabledReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionGatePanel: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                Text("Host Permissions")
                    .font(.title3.weight(.semibold))
                Text("Checking whether your Mac host has the required permissions before remote control starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.permissionGatePhase == .checking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking permissions...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Layout.fieldHorizontalPadding)
                .padding(.vertical, Layout.fieldVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
            } else {
                permissionRow(
                    title: "Accessibility",
                    granted: viewModel.hostPermissionState.accessibilityGranted
                ) {
                    viewModel.requestHostPermissionFix(.accessibility)
                }

                permissionRow(
                    title: "Screen Recording",
                    granted: viewModel.hostPermissionState.screenRecordingGranted
                ) {
                    viewModel.requestHostPermissionFix(.screenRecording)
                }
            }

            if viewModel.hostPermissionState.allGranted == false {
                Button("I've given access. Refresh status") {
                    viewModel.refreshHostPermissionStatus()
                }
                .buttonStyle(LiquidGlassButtonStyle(tint: .gray))
                .frame(maxWidth: .infinity)
            }

            if viewModel.canContinueAfterPermissionGate {
                Button("Continue") {
                    viewModel.completePermissionGate()
                }
                .buttonStyle(LiquidGlassButtonStyle(tint: .blue))
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        onFixTapped: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 0)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access") {
                    onFixTapped()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Layout.fieldHorizontalPadding)
        .padding(.vertical, Layout.fieldVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))
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

    private var fixedScreenPreview: some View {
        FixedScreenPreview(
            preview: viewModel.screenPreview,
            zoomScale: CGFloat(previewZoomLevel),
            isAutoFollowEnabled: previewZoomLevel > 1.0,
            isVirtualOverscanEnabled: isVirtualOverscanEnabled,
            videoGravity: isImmersiveLandscapeModeEnabled ? .resizeAspect : .resizeAspectFill,
            showsBlackBackdrop: isImmersiveLandscapeModeEnabled == false
        )
        .id(previewSurfaceVersion)
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedField = nil
                dismissTypingCapture()
            }
        )
    }

    private var isConnectedContentVisible: Bool {
        showConnectedLayout
            || isDisconnectTransitionActive
            || isLivePreviewVisible
            || isPreviewSectionVisible
            || isStatsSectionVisible
            || isKeyboardSectionVisible
            || isTrackpadSectionVisible
            || isStartupOverlayVisible
            || isDisconnectPreviewOverlayVisible
    }

    private var shouldUseImmersiveLandscapeOrientation: Bool {
        isImmersiveLandscapeModeEnabled
            && viewModel.isPaired
            && (showConnectedLayout || isDisconnectTransitionActive)
    }

    private func applyOrientationPolicy() {
        IMoteOrientationController.setImmersiveModeEnabled(shouldUseImmersiveLandscapeOrientation)
    }

    private func beginConnectSequence() {
        startupTask?.cancel()
        revealTask?.cancel()
        disconnectTask?.cancel()
        isControlledDisconnectFlow = false
        shouldForgetOnControlledDisconnect = false
        lockedDisconnectPreviewAspectRatio = nil
        isDisconnectTransitionActive = false
        showConnectedLayout = false
        connectionScreenOpacity = 1
        connectedScreenOpacity = 1
        isDisconnectPreviewOverlayVisible = false
        disconnectPreviewOverlayOpacity = 0
        isStartupOverlayVisible = false
        isStartupProgressVisible = false
        startupProgress = 0
        isLivePreviewVisible = false
        isPreviewSectionVisible = false
        isStatsSectionVisible = false
        isKeyboardSectionVisible = false
        isTrackpadSectionVisible = false
        startPreviewResyncMonitor()

        startupTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.35)) {
                connectionScreenOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            showConnectedLayout = true
            withAnimation(.easeInOut(duration: 0.35)) {
                isPreviewSectionVisible = true
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isStartupOverlayVisible = true
                isStartupProgressVisible = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            isStartupProgressVisible = true
            startupProgress = 0
            withAnimation(.linear(duration: 2.0)) {
                startupProgress = 1
            }

            let minimumEnd = ContinuousClock.now + .seconds(2)
            while viewModel.screenPreview.hasFrame == false {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard Task.isCancelled == false else { return }
            }
            let now = ContinuousClock.now
            if now < minimumEnd {
                try? await Task.sleep(for: now.duration(to: minimumEnd))
                guard Task.isCancelled == false else { return }
            }

            withAnimation(.easeInOut(duration: 0.35)) {
                isLivePreviewVisible = true
                isStartupProgressVisible = false
            }
            withAnimation(.easeInOut(duration: 0.35)) {
                isStartupOverlayVisible = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isStatsSectionVisible = true
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isKeyboardSectionVisible = true
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isTrackpadSectionVisible = true
            }
        }
    }

    private func resetTransitionState() {
        startupTask?.cancel()
        revealTask?.cancel()
        disconnectTask?.cancel()
        startupTask = nil
        revealTask = nil
        disconnectTask = nil
        isControlledDisconnectFlow = false
        shouldForgetOnControlledDisconnect = false
        lockedDisconnectPreviewAspectRatio = nil
        showConnectedLayout = false
        isDisconnectTransitionActive = false
        connectionScreenOpacity = 1
        connectedScreenOpacity = 1
        isStartupProgressVisible = false
        startupProgress = 0
        isLivePreviewVisible = false
        isDisconnectPreviewOverlayVisible = false
        disconnectPreviewOverlayOpacity = 0
        isStartupOverlayVisible = false
        isPreviewSectionVisible = false
        isStatsSectionVisible = false
        isKeyboardSectionVisible = false
        isTrackpadSectionVisible = false
        stopPreviewResyncMonitor()
    }

    private func beginControlledDisconnectSequence(forgetDevice: Bool) {
        guard showConnectedLayout else { return }
        isControlledDisconnectFlow = true
        shouldForgetOnControlledDisconnect = forgetDevice
        beginDisconnectSequence()
    }

    private func beginDisconnectSequence() {
        startupTask?.cancel()
        revealTask?.cancel()
        disconnectTask?.cancel()
        isDisconnectTransitionActive = true
        showConnectedLayout = true
        lockedDisconnectPreviewAspectRatio = max(viewModel.screenPreview.sourceAspectRatio, 0.01)
        connectedScreenOpacity = 1
        connectionScreenOpacity = 0
        isStartupOverlayVisible = false
        isStartupProgressVisible = false
        isDisconnectPreviewOverlayVisible = false
        disconnectPreviewOverlayOpacity = 0

        disconnectTask = Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.35)) {
                isTrackpadSectionVisible = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isKeyboardSectionVisible = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isStatsSectionVisible = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            withAnimation(.easeInOut(duration: 0.35)) {
                isLivePreviewVisible = false
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            isDisconnectPreviewOverlayVisible = true
            withAnimation(.easeInOut(duration: 0.35)) {
                disconnectPreviewOverlayOpacity = 1
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard Task.isCancelled == false else { return }

            if shouldForgetOnControlledDisconnect {
                viewModel.forgetCurrentDeviceTrustOnMac()
                shouldForgetOnControlledDisconnect = false
            }
            if isControlledDisconnectFlow {
                viewModel.disconnect()
            }

            withAnimation(.easeInOut(duration: 0.35)) {
                disconnectPreviewOverlayOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard Task.isCancelled == false else { return }

            isDisconnectPreviewOverlayVisible = false
            isDisconnectTransitionActive = false
            showConnectedLayout = false
            isControlledDisconnectFlow = false
            lockedDisconnectPreviewAspectRatio = nil
            connectedScreenOpacity = 0
            connectionScreenOpacity = 0

            withAnimation(.easeInOut(duration: 0.35)) {
                connectionScreenOpacity = 1
            }
        }
    }

    private func cancelDisconnectSequence() {
        disconnectTask?.cancel()
        disconnectTask = nil
        isDisconnectPreviewOverlayVisible = false
        disconnectPreviewOverlayOpacity = 0
        isDisconnectTransitionActive = false
        isControlledDisconnectFlow = false
        shouldForgetOnControlledDisconnect = false
        lockedDisconnectPreviewAspectRatio = nil
        connectedScreenOpacity = 1
        connectionScreenOpacity = 0
    }

    private func startPreviewResyncMonitor() {
        stopPreviewResyncMonitor()
        lastPreviewResyncAt = nil
        previewResyncTask = Task { @MainActor in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard Task.isCancelled == false else { return }
                guard viewModel.isPaired else { continue }
                guard showConnectedLayout || isDisconnectTransitionActive else { continue }
                guard isStartupOverlayVisible == false, isDisconnectPreviewOverlayVisible == false else { continue }
                guard isLivePreviewVisible else { continue }
                guard viewModel.screenPreview.hasFrame else { continue }
                guard let lastFrameDate = viewModel.screenPreview.lastFrameReceivedAt else { continue }

                let frameStaleness = Date().timeIntervalSince(lastFrameDate)
                guard frameStaleness >= 1.2 else { continue }

                if let lastResync = lastPreviewResyncAt,
                   Date().timeIntervalSince(lastResync) < 2.0 {
                    continue
                }

                lastPreviewResyncAt = Date()
                viewModel.requestStreamResync()

                if frameStaleness >= 2.5 {
                    previewSurfaceVersion &+= 1
                    viewModel.screenPreview.displayBridge.flush()
                }
            }
        }
    }

    private func handleOrientationDidChange() {
        guard viewModel.isPaired else { return }
        guard showConnectedLayout || isDisconnectTransitionActive else { return }
        let now = Date()
        if let last = lastOrientationResyncAt, now.timeIntervalSince(last) < 0.6 {
            return
        }
        lastOrientationResyncAt = now
        forcePreviewPipelineResync(reason: "orientationChange")
    }

    private func forcePreviewPipelineResync(reason: String) {
        guard viewModel.isPaired else { return }
        previewSurfaceVersion &+= 1
        viewModel.requestLocalPreviewDecoderResync()
        viewModel.screenPreview.displayBridge.flush()
        viewModel.requestStreamResync()

        if let missingSince = viewModel.screenPreview.displayBridge.missingLayerSince,
           Date().timeIntervalSince(missingSince) >= 0.8 {
            previewSurfaceVersion &+= 1
            viewModel.screenPreview.displayBridge.flush()
            viewModel.requestStreamResync()
        }
    }

    private func stopPreviewResyncMonitor() {
        previewResyncTask?.cancel()
        previewResyncTask = nil
        lastPreviewResyncAt = nil
        lastOrientationResyncAt = nil
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
                    settingsTitle("Zoom level", systemImage: "plus.magnifyingglass")
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
                    settingsTitle("Zoom level", systemImage: "plus.magnifyingglass")
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

            HStack(spacing: 12) {
                settingsTitle("Immersive landscape preview", systemImage: "rectangle.inset.filled.and.person.filled")
                Spacer(minLength: 0)
                Toggle("", isOn: $isImmersiveLandscapeModeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))

            HStack(spacing: 12) {
                settingsTitle("Virtual overscan", systemImage: "viewfinder")
                Spacer(minLength: 0)
                Toggle("", isOn: $isVirtualOverscanEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))

            HStack(spacing: 12) {
                settingsTitle("Experimental", systemImage: "flask")
                Spacer(minLength: 0)
                Toggle("", isOn: $isEyeCursorExperimentalEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, Layout.fieldHorizontalPadding)
            .padding(.vertical, Layout.fieldVerticalPadding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))

            if isEyeCursorExperimentalEnabled {
                HStack(spacing: 12) {
                    settingsTitle("Eye cursor control", systemImage: "eye")
                    Spacer(minLength: 0)
                    Toggle("", isOn: $isEyeCursorEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, Layout.fieldHorizontalPadding)
                .padding(.vertical, Layout.fieldVerticalPadding)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Layout.fieldCornerRadius, style: .continuous))

                Text("Experimental. Uses front camera to map eye movement to cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Layout.fieldHorizontalPadding)
            }

            VStack(alignment: .leading, spacing: 8) {
                settingsTitle("Preview quality", systemImage: "dial.medium")

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

            VStack(alignment: .leading, spacing: 8) {
                settingsTitle("Audio source", systemImage: "speaker.wave.2")

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func settingsTitle(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
            Text(text)
                .font(.footnote.weight(.semibold))
        }
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
                    onModifierTap: { modifier in
                        viewModel.sendModifierTap(modifier)
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
                    },
                    onFourFingerSwipe: { direction in
                        switch direction {
                        case .up:
                            viewModel.sendNamedKey(.upArrow, modifiers: [.control])
                        case .down:
                            viewModel.sendNamedKey(.downArrow, modifiers: [.control])
                        case .left:
                            viewModel.sendNamedKey(.leftArrow, modifiers: [.control])
                        case .right:
                            viewModel.sendNamedKey(.rightArrow, modifiers: [.control])
                        }
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

    private func resolvedTopInset(geometrySafeAreaTop: CGFloat) -> CGFloat {
        let windowTopInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
        return max(geometrySafeAreaTop, windowTopInset)
    }

    private func dismissTypingCapture() {
        if isTypingCaptureActive {
            isTypingCaptureActive = false
        }
    }

    private func updateEyeCursorState() {
        if isEyeCursorExperimentalEnabled && isEyeCursorEnabled && viewModel.isPaired {
            eyeCursorController.start()
        } else {
            eyeCursorController.stop()
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
        switch viewModel.connectionTargetMode {
        case .localDiscovery:
            guard viewModel.selectedService != nil else {
                return false
            }
        case .manualAddress:
            let trimmedHost = viewModel.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedHost.isEmpty == false else {
                return false
            }
            guard let parsedPort = Int(viewModel.manualPortText), (1...65_535).contains(parsedPort) else {
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
            let trimmedHost = viewModel.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedHost.isEmpty {
                return "Enter the remote host or IP address."
            }
            if let parsedPort = Int(viewModel.manualPortText), (1...65_535).contains(parsedPort) == false {
                return "Enter a valid port between 1 and 65535."
            }
            if Int(viewModel.manualPortText) == nil {
                return "Enter a valid port between 1 and 65535."
            }
        }
        if viewModel.isTrustedAutoReconnect == false && viewModel.pairingCode.count != 6 {
            return "Enter the 6-digit pairing code."
        }
        return ""
    }

    private var shouldShowConnectDisabledReason: Bool {
        if viewModel.connectionTargetMode == .manualAddress,
           connectDisabledReason == "Enter the remote host or IP address." {
            return false
        }
        return connectDisabledReason.isEmpty == false
    }
}
