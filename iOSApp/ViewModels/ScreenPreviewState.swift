import Combine
import AVFoundation
import CoreImage
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ScreenPreviewState: ObservableObject {
    @Published private(set) var hasFrame = false
    @Published private(set) var lastFrameReceivedAt: Date?
    @Published private(set) var sourceAspectRatio: CGFloat = 16.0 / 10.0
    @Published var statsLabel = "No frames yet"
    @Published var hostCaptureStatusLabel = "Host: unknown"
    @Published private(set) var followAnchor = UnitPoint.center
    @Published private(set) var previewGlowColor = Color(red: 0.22, green: 0.28, blue: 0.36)
    let displayBridge = SampleBufferDisplayBridge()

    let zoomScale: CGFloat = 2.2

    private var frameTimestamps: [Date] = []
    private var smoothedFPS: Double?
    private var displayedFPS: Int?
    private var smoothedDecodeLatencyMs: Double?
    private var timerCancellable: AnyCancellable?
    private var glowSampleCounter = 0
    private var smoothedGlowRGB: SIMD3<Double>?
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false
    ])

    init() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatsLabel()
            }
    }

    func reset() {
        hasFrame = false
        lastFrameReceivedAt = nil
        sourceAspectRatio = 16.0 / 10.0
        frameTimestamps.removeAll()
        statsLabel = "No frames yet"
        hostCaptureStatusLabel = "Host: unknown"
        followAnchor = .center
        smoothedFPS = nil
        displayedFPS = nil
        smoothedDecodeLatencyMs = nil
        glowSampleCounter = 0
        smoothedGlowRGB = nil
        previewGlowColor = Color(red: 0.22, green: 0.28, blue: 0.36)
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
            updatePreviewGlowColor(from: pixelBuffer)
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

    func updateHostCaptureStatus(routeLabel: String?, displayCount: Int?, isActive: Bool?) {
        let normalizedRoute: String
        if let routeLabel, routeLabel.isEmpty == false {
            normalizedRoute = routeLabel
        } else {
            normalizedRoute = "Unknown"
        }

        let displaySummary: String
        if let displayCount {
            displaySummary = "\(displayCount) display" + (displayCount == 1 ? "" : "s")
        } else {
            displaySummary = "display count unknown"
        }

        let activitySummary: String
        switch isActive {
        case true:
            activitySummary = "live"
        case false:
            activitySummary = "no frames"
        case nil:
            activitySummary = "state unknown"
        }

        hostCaptureStatusLabel = "Host: \(normalizedRoute) • \(displaySummary) • \(activitySummary)"
    }

    private func recordArrival() {
        let now = Date()
        lastFrameReceivedAt = now
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

        let candidateFPS = Int((smoothedFPS ?? instantFPS).rounded())
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
        statsLabel = "~\(fps) fps • decode \(decodeMs) ms • render \(ageMs) ms"
    }

    private func updatePreviewGlowColor(from pixelBuffer: CVPixelBuffer) {
        glowSampleCounter += 1
        guard glowSampleCounter % 6 == 0 else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.isEmpty == false else { return }

        // Sample a centered region to avoid unstable colors from edge UI chrome.
        let sampleRect = extent.insetBy(dx: extent.width * 0.22, dy: extent.height * 0.28)
        let filterInputExtent = CIVector(cgRect: sampleRect)
        guard
            let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: filterInputExtent
            ]),
            let outputImage = filter.outputImage
        else {
            return
        }

        var rgba = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            outputImage,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let sampled = SIMD3<Double>(
            Double(rgba[0]) / 255.0,
            Double(rgba[1]) / 255.0,
            Double(rgba[2]) / 255.0
        )

        let blendAlpha = 0.18
        let blended: SIMD3<Double>
        if let current = smoothedGlowRGB {
            blended = current + (sampled - current) * blendAlpha
        } else {
            blended = sampled
        }
        smoothedGlowRGB = blended

        previewGlowColor = Color(
            red: min(max(blended.x, 0), 1),
            green: min(max(blended.y, 0), 1),
            blue: min(max(blended.z, 0), 1)
        )
    }
}

@MainActor
final class SampleBufferDisplayBridge {
    private var displayLayers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    private let stateLock = NSLock()
    private var lastMissingLayerAt: Date?

    var isLayerAttached: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return displayLayers.allObjects.isEmpty == false
    }

    var missingLayerSince: Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastMissingLayerAt
    }

    func attach(layer: AVSampleBufferDisplayLayer) {
        stateLock.lock()
        if displayLayers.contains(layer) == false {
            displayLayers.add(layer)
        }
        lastMissingLayerAt = nil
        stateLock.unlock()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let layers = currentLayers()
        guard layers.isEmpty == false else {
            stateLock.lock()
            if lastMissingLayerAt == nil {
                lastMissingLayerAt = Date()
            }
            stateLock.unlock()
            return
        }
        stateLock.lock()
        lastMissingLayerAt = nil
        stateLock.unlock()

        for layer in layers {
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
    }

    func flush() {
        let layers = currentLayers()
        guard layers.isEmpty == false else { return }
        for layer in layers {
            if #available(iOS 18.0, *) {
                layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            } else {
                layer.flushAndRemoveImage()
            }
        }
    }

    private func currentLayers() -> [AVSampleBufferDisplayLayer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return displayLayers.allObjects
    }
}
