import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CapturedPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

actor MacScreenCaptureProvider {
    private static let targetFPS: Int32 = 60

    private var contentFilter: SCContentFilter?
    private var sourceWidth: CGFloat = 0
    private var sourceHeight: CGFloat = 0
    private var displayFrame: CGRect = .zero
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private let outputQueue = DispatchQueue(label: "remote.keyboard.capture.output")
    private var latestPixelBuffer: CapturedPixelBuffer?
    private var activeMaxWidth: CGFloat = 0

    func makeFramePixelBuffer(maxWidth: CGFloat = 1920) async -> CapturedPixelBuffer? {
        do {
            if contentFilter == nil {
                try await prepareCaptureFilter()
            }

            guard let filter = contentFilter,
                  sourceWidth > 0,
                  sourceHeight > 0 else {
                return nil
            }

            try await ensureCaptureStream(filter: filter, maxWidth: maxWidth)
            return latestPixelBuffer
        } catch {
            return nil
        }
    }

    func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
            if let streamOutput {
                try? stream.removeStreamOutput(streamOutput, type: .screen)
            }
        }
        self.stream = nil
        self.streamOutput = nil
        self.latestPixelBuffer = nil
        self.activeMaxWidth = 0
    }

    func normalizedCursorPosition() -> CGPoint? {
        guard displayFrame.isEmpty == false else { return nil }

        let location = NSEvent.mouseLocation
        let relativeX = (location.x - displayFrame.minX) / displayFrame.width
        let relativeY = (location.y - displayFrame.minY) / displayFrame.height

        let clampedX = min(max(relativeX, 0), 1)
        let clampedY = min(max(1 - relativeY, 0), 1)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func prepareCaptureFilter() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            return
        }

        sourceWidth = CGFloat(display.width)
        sourceHeight = CGFloat(display.height)
        displayFrame = display.frame
        contentFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    private func ensureCaptureStream(filter: SCContentFilter, maxWidth: CGFloat) async throws {
        if stream == nil || abs(activeMaxWidth - maxWidth) > 0.5 {
            try await rebuildCaptureStream(filter: filter, maxWidth: maxWidth)
        }
    }

    private func rebuildCaptureStream(filter: SCContentFilter, maxWidth: CGFloat) async throws {
        if let stream {
            try? await stream.stopCapture()
            if let streamOutput {
                try? stream.removeStreamOutput(streamOutput, type: .screen)
            }
        }

        let scale = min(1.0, maxWidth / sourceWidth)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(sourceWidth * scale))
        config.height = max(1, Int(sourceHeight * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.targetFPS)
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let streamOutput = StreamOutput(owner: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = streamOutput
        self.activeMaxWidth = maxWidth
    }

    fileprivate func consumeFrame(_ pixelBuffer: CapturedPixelBuffer) {
        latestPixelBuffer = pixelBuffer
    }
}
private final class StreamOutput: NSObject, SCStreamOutput {
    private weak var owner: MacScreenCaptureProvider?

    init(owner: MacScreenCaptureProvider) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        guard let owner else { return }

        let frame = CapturedPixelBuffer(value: imageBuffer)
        Task {
            await owner.consumeFrame(frame)
        }
    }
}
