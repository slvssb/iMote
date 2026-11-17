import AVFoundation
import SwiftUI
import UIKit

enum PhoneFocusField: Hashable {
    case pairingCode
}

enum PhoneTab: Hashable {
    case devices
    case remote
    case settings
}

struct FixedScreenPreview: View {
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

struct SampleBufferPreviewView: UIViewRepresentable {
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

final class SampleBufferDisplayLayerView: UIView {
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

struct PreviewStatsStripView: View {
    @ObservedObject var preview: ScreenPreviewState
    let onSettingsTapped: () -> Void

    var body: some View {
        ZStack {
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(preview.statsLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(preview.hostCaptureStatusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
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
                .accessibilityLabel("Settings")
                .padding(.trailing, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

struct MacStartupOverlay: View {
    let progress: Double
    var progressOpacity: Double = 1

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 20) {
                Image(systemName: "applelogo")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .accessibilityHidden(true)

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 148, height: 4)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 148 * progress, height: 4)
                }
                .opacity(progressOpacity)
                .accessibilityLabel("Starting preview")
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MacCenteredLogoOverlay: View {
    var body: some View {
        ZStack {
            Color.black
            Image(systemName: "applelogo")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Disconnected")
    }
}

enum TrustedHostPresentation {
    static func fingerprint(for record: TrustedHostStore.Record) -> String {
        guard let data = Data(base64Encoded: record.signingKey) else {
            return "Unreadable signing key"
        }
        return IdentityFingerprint.displayString(forPublicKey: data)
    }

    static func endpointLines(for record: TrustedHostStore.Record) -> [String] {
        record.endpoints.map { key in
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return key }
            switch parts[0] {
            case "h":
                return "\(parts[1]):\(parts[2])"
            case "b":
                return "\(parts[1]) on port \(parts[2])"
            default:
                return key
            }
        }
    }
}

struct PhoneHostPermissionList: View {
    @ObservedObject var viewModel: IOSKeyboardViewModel

    var body: some View {
        if viewModel.permissionGatePhase == .checking {
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking permissions...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
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
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        onFixTapped: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(title) granted")
            } else {
                Button("Grant Access") {
                    onFixTapped()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Grant \(title) access")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
