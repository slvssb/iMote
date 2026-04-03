import Combine
import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ScreenPreviewState: ObservableObject {
    @Published private(set) var hasFrame = false
    @Published private(set) var sourceAspectRatio: CGFloat = 16.0 / 10.0
    @Published var statsLabel = "No frames yet"
    @Published private(set) var followAnchor = UnitPoint.center
    let displayBridge = SampleBufferDisplayBridge()

    let zoomScale: CGFloat = 2.2

    private var frameTimestamps: [Date] = []
    private var smoothedFPS: Double?
    private var displayedFPS: Int?
    private var smoothedDecodeLatencyMs: Double?
    private var smoothedBitrateKbps: Double?
    private var videoCodecLabel: String?
    private var timerCancellable: AnyCancellable?

    init() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatsLabel()
            }
    }

    func reset() {
        hasFrame = false
        sourceAspectRatio = 16.0 / 10.0
        frameTimestamps.removeAll()
        statsLabel = "No frames yet"
        followAnchor = .center
        smoothedFPS = nil
        displayedFPS = nil
        smoothedDecodeLatencyMs = nil
        smoothedBitrateKbps = nil
        videoCodecLabel = nil
        displayBridge.flush()
    }

    func consumeFrameData(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        consumeFrameImage(image)
    }

    func consumeFrameImage(_ image: UIImage) {
        _ = image
        hasFrame = true
        recordArrival()
    }

    func consumeDecodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let pixelBuffer = sampleBuffer.imageBuffer {
            let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            if height > 0 {
                sourceAspectRatio = width / height
            }
        }
        hasFrame = true
        displayBridge.enqueue(sampleBuffer)
        recordArrival()
    }

    func updateCursorPosition(x: Double, y: Double) {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)

        let alpha = 0.22
        let nextX = followAnchor.x + (clampedX - followAnchor.x) * alpha
        let nextY = followAnchor.y + (clampedY - followAnchor.y) * alpha
        followAnchor = UnitPoint(x: nextX, y: nextY)
    }

    func updateDecodeLatency(ms: Double) {
        if let current = smoothedDecodeLatencyMs {
            // Smooth noisy frame-to-frame decode times for a stable strip.
            smoothedDecodeLatencyMs = (current * 0.75) + (ms * 0.25)
        } else {
            smoothedDecodeLatencyMs = ms
        }
        updateStatsLabel()
    }

    func updateVideoCodecLabel(_ label: String) {
        videoCodecLabel = label
        updateStatsLabel()
    }

    func updateEncoderBitrate(kbps: Int) {
        let value = Double(max(0, kbps))
        if let current = smoothedBitrateKbps {
            smoothedBitrateKbps = (current * 0.75) + (value * 0.25)
        } else {
            smoothedBitrateKbps = value
        }
        updateStatsLabel()
    }

    private func recordArrival() {
        let now = Date()
        frameTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-5)
        frameTimestamps.removeAll { $0 < cutoff }
        updateStatsLabel()
    }

    private func updateStatsLabel() {
        guard let last = frameTimestamps.last else {
            statsLabel = "No frames yet"
            return
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-5)
        frameTimestamps.removeAll { $0 < cutoff }

        let instantFPS = Double(frameTimestamps.filter { $0 >= now.addingTimeInterval(-1) }.count)
        if let current = smoothedFPS {
            smoothedFPS = (current * 0.7) + (instantFPS * 0.3)
        } else {
            smoothedFPS = instantFPS
        }

        let candidateFPS = min(60, Int((smoothedFPS ?? instantFPS).rounded()))
        if let currentDisplayed = displayedFPS {
            // Avoid visual churn for tiny FPS fluctuations (e.g. 60 <-> 61).
            if abs(candidateFPS - currentDisplayed) >= 3 {
                displayedFPS = candidateFPS
            }
        } else {
            displayedFPS = candidateFPS
        }

        let fps = displayedFPS ?? candidateFPS
        let ageMs = Int(now.timeIntervalSince(last) * 1000)
        let decodeMs = Int((smoothedDecodeLatencyMs ?? 0).rounded())

        var label = "~\(fps) fps • decode \(decodeMs) ms • render \(ageMs) ms"
        if let smoothedBitrateKbps {
            if smoothedBitrateKbps >= 1000 {
                label += String(format: " • bitrate %.1f Mbps", smoothedBitrateKbps / 1000)
            } else {
                label += " • bitrate \(Int(smoothedBitrateKbps.rounded())) Kbps"
            }
        }
        if let videoCodecLabel {
            label += " • codec \(videoCodecLabel)"
        }
        statsLabel = label
    }
}

@MainActor
final class SampleBufferDisplayBridge {
    weak var displayLayer: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        layer.videoGravity = .resizeAspect
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let layer = displayLayer else { return }
        if #available(iOS 18.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            }
            renderer.enqueue(sampleBuffer)
        } else {
            if layer.status == .failed {
                layer.flushAndRemoveImage()
            }
            layer.enqueue(sampleBuffer)
        }
    }

    func flush() {
        guard let layer = displayLayer else { return }
        if #available(iOS 18.0, *) {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            layer.flushAndRemoveImage()
        }
    }
}
