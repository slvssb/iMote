import SwiftUI
import UIKit

struct PhoneRemoteView: View {
    private enum Layout {
        static let sectionSpacing: CGFloat = 16
        static let panelSpacing: CGFloat = 14
        static let contentPadding: CGFloat = 18
        static let verticalPadding: CGFloat = 16
        static let contentMaxWidth: CGFloat = 620
        static let touchpadHeight: CGFloat = 210
        static let mouseMotionMultiplier: Double = 1.45
        static let scrollMultiplier: Double = 1.2
        static let previewHorizontalInset: CGFloat = 4
    }

    @ObservedObject var viewModel: IOSKeyboardViewModel
    @FocusState.Binding var focusedField: PhoneFocusField?
    @Binding var isTypingCaptureActive: Bool
    @Binding var isConfigSheetPresented: Bool

    let previewZoomLevel: Double
    let isVirtualOverscanEnabled: Bool
    let isImmersiveLandscapeModeEnabled: Bool
    let showConnectedLayout: Bool
    let isDisconnectTransitionActive: Bool
    let lockedDisconnectPreviewAspectRatio: CGFloat?
    let isLivePreviewVisible: Bool
    let isStartupOverlayVisible: Bool
    let isStartupProgressVisible: Bool
    let startupProgress: Double
    let isDisconnectPreviewOverlayVisible: Bool
    let disconnectPreviewOverlayOpacity: Double
    let isPreviewSectionVisible: Bool
    let isStatsSectionVisible: Bool
    let isKeyboardSectionVisible: Bool
    let isTrackpadSectionVisible: Bool
    let connectedScreenOpacity: Double
    let previewSurfaceVersion: Int
    let dismissTypingCapture: @MainActor () -> Void
    let onShowDevices: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if showConnectedLayout || isDisconnectTransitionActive {
                session
            } else {
                disconnected
            }
        }
    }

    private var disconnected: some View {
        ContentUnavailableView {
            Label("Not connected", systemImage: "macbook.and.iphone")
        } description: {
            Text("Choose a Mac on Devices, enter the pairing code, and connect. The preview, trackpad, and keyboard open here.")
        } actions: {
            Button("Go to Devices", action: onShowDevices)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var session: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                let topInset = resolvedTopInset(geometrySafeAreaTop: geometry.safeAreaInsets.top)
                let previewAspectSource = lockedDisconnectPreviewAspectRatio ?? viewModel.screenPreview.sourceAspectRatio
                let previewAspect = max(previewAspectSource, 0.01)
                let previewWidth = max(geometry.size.width - (Layout.previewHorizontalInset * 2), 1)
                let previewHeight = previewWidth / previewAspect

                if isImmersiveLandscapeModeEnabled {
                    immersiveSession(geometry: geometry, topInset: topInset)
                } else {
                    portraitSession(previewHeight: previewHeight, topInset: topInset)
                }
            }
            .ignoresSafeArea(edges: isImmersiveLandscapeModeEnabled ? .all : .top)
        }
    }

    private func immersiveSession(geometry: GeometryProxy, topInset: CGFloat) -> some View {
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
                .accessibilityLabel("Trackpad")

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
                    .accessibilityLabel("Settings")
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
                    .accessibilityLabel("Keyboard")
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
    }

    private func portraitSession(previewHeight: CGFloat, topInset: CGFloat) -> some View {
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
        .accessibilityLabel("Mac screen")
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

    private var previewStatsStrip: some View {
        VStack(spacing: 6) {
            PreviewStatsStripView(preview: viewModel.screenPreview) {
                focusedField = nil
                dismissTypingCapture()
                isConfigSheetPresented = true
            }
            if showConnectedLayout, let error = viewModel.lastError, error.isEmpty == false {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
            }
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
            .accessibilityLabel(isTypingCaptureActive ? "Keyboard focused" : "Keyboard idle")
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
            .accessibilityLabel("Trackpad")
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
        .accessibilityElement(children: .combine)
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

    private func resolvedTopInset(geometrySafeAreaTop: CGFloat) -> CGFloat {
        let windowTopInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
        return max(geometrySafeAreaTop, windowTopInset)
    }
}
