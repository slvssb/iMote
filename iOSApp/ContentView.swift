import SwiftUI
import UIKit

struct ContentView: View {
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
    @State private var selectedTab: PhoneTab = .devices
    @StateObject private var eyeCursorController = EyeCursorController()
    @FocusState private var focusedField: PhoneFocusField?

    private var hidesTabBarForImmersiveRemote: Bool {
        selectedTab == .remote
            && isImmersiveLandscapeModeEnabled
            && (showConnectedLayout || isDisconnectTransitionActive)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Devices", systemImage: "macbook", value: PhoneTab.devices) {
                NavigationStack {
                    PhoneDevicesView(
                        viewModel: viewModel,
                        focusedField: $focusedField,
                        isTypingCaptureActive: $isTypingCaptureActive,
                        showConnectedLayout: showConnectedLayout,
                        isDisconnectTransitionActive: isDisconnectTransitionActive,
                        onDisconnect: { beginControlledDisconnectSequence(forgetDevice: false) },
                        onForgetAndDisconnect: { beginControlledDisconnectSequence(forgetDevice: true) },
                        onOpenRemote: { selectedTab = .remote }
                    )
                    .navigationTitle("Devices")
                    .navigationBarTitleDisplayMode(.large)
                    .opacity((showConnectedLayout || isDisconnectTransitionActive) ? 1 : connectionScreenOpacity)
                }
            }

            Tab("Remote", systemImage: "rectangle.and.hand.point.up.left", value: PhoneTab.remote) {
                NavigationStack {
                    PhoneRemoteView(
                        viewModel: viewModel,
                        focusedField: $focusedField,
                        isTypingCaptureActive: $isTypingCaptureActive,
                        isConfigSheetPresented: $isConfigSheetPresented,
                        previewZoomLevel: previewZoomLevel,
                        isVirtualOverscanEnabled: isVirtualOverscanEnabled,
                        isImmersiveLandscapeModeEnabled: isImmersiveLandscapeModeEnabled,
                        showConnectedLayout: showConnectedLayout,
                        isDisconnectTransitionActive: isDisconnectTransitionActive,
                        lockedDisconnectPreviewAspectRatio: lockedDisconnectPreviewAspectRatio,
                        isLivePreviewVisible: isLivePreviewVisible,
                        isStartupOverlayVisible: isStartupOverlayVisible,
                        isStartupProgressVisible: isStartupProgressVisible,
                        startupProgress: startupProgress,
                        isDisconnectPreviewOverlayVisible: isDisconnectPreviewOverlayVisible,
                        disconnectPreviewOverlayOpacity: disconnectPreviewOverlayOpacity,
                        isPreviewSectionVisible: isPreviewSectionVisible,
                        isStatsSectionVisible: isStatsSectionVisible,
                        isKeyboardSectionVisible: isKeyboardSectionVisible,
                        isTrackpadSectionVisible: isTrackpadSectionVisible,
                        connectedScreenOpacity: connectedScreenOpacity,
                        previewSurfaceVersion: previewSurfaceVersion,
                        dismissTypingCapture: { dismissTypingCapture() },
                        onShowDevices: { selectedTab = .devices }
                    )
                    .navigationTitle("Remote")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(showConnectedLayout || isDisconnectTransitionActive ? .hidden : .visible, for: .navigationBar)
                }
            }

            Tab("Settings", systemImage: "gearshape", value: PhoneTab.settings) {
                NavigationStack {
                    PhoneSettingsView(
                        viewModel: viewModel,
                        showsSessionActions: showConnectedLayout,
                        onDisconnect: { beginControlledDisconnectSequence(forgetDevice: false) },
                        onForgetAndDisconnect: { beginControlledDisconnectSequence(forgetDevice: true) },
                        dismissTypingCapture: { dismissTypingCapture() }
                    )
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.large)
                }
            }
        }
        .toolbar(hidesTabBarForImmersiveRemote ? .hidden : .visible, for: .tabBar)
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
        .onChange(of: viewModel.shouldShowPermissionGate) { _, show in
            if show {
                selectedTab = .devices
            }
        }
        .sheet(isPresented: $isConfigSheetPresented) {
            NavigationStack {
                PhoneSettingsView(
                    viewModel: viewModel,
                    showsSessionActions: true,
                    onDisconnect: {
                        beginControlledDisconnectSequence(forgetDevice: false)
                        isConfigSheetPresented = false
                    },
                    onForgetAndDisconnect: {
                        beginControlledDisconnectSequence(forgetDevice: true)
                        isConfigSheetPresented = false
                    },
                    dismissTypingCapture: { dismissTypingCapture() }
                )
                .navigationTitle("App Settings")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .ignoresSafeArea(.keyboard, edges: .all)
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
        selectedTab = .remote
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
            let previewTimeout = ContinuousClock.now + .seconds(6)
            while viewModel.screenPreview.hasFrame == false {
                if ContinuousClock.now >= previewTimeout {
                    viewModel.notePreviewDidNotStart()
                    break
                }
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
                let forgot = await viewModel.forgetCurrentDeviceTrustOnMac()
                shouldForgetOnControlledDisconnect = false
                guard forgot, Task.isCancelled == false else {
                    restoreConnectedControlsAfterFailedForget()
                    return
                }
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
            if selectedTab == .remote {
                selectedTab = .devices
            }
        }
    }

    private func restoreConnectedControlsAfterFailedForget() {
        disconnectTask = nil
        isDisconnectPreviewOverlayVisible = false
        disconnectPreviewOverlayOpacity = 0
        isDisconnectTransitionActive = false
        isControlledDisconnectFlow = false
        lockedDisconnectPreviewAspectRatio = nil
        showConnectedLayout = true
        connectedScreenOpacity = 1
        connectionScreenOpacity = 0
        isPreviewSectionVisible = true
        isLivePreviewVisible = true
        isStatsSectionVisible = true
        isKeyboardSectionVisible = true
        isTrackpadSectionVisible = true
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

    private func clampedZoom(_ value: Double) -> Double {
        min(3.0, max(1.0, value))
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
}
