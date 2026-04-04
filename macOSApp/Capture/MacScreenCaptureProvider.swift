import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CapturedPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

struct CapturedAudioSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
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
    private var audioCaptureSource: AudioCaptureSource = .systemOutput
    private var audioSampleHandler: ((CapturedAudioSampleBuffer) -> Void)?

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
                try? stream.removeStreamOutput(streamOutput, type: .audio)
                try? stream.removeStreamOutput(streamOutput, type: .microphone)
            }
        }
        self.stream = nil
        self.streamOutput = nil
        self.latestPixelBuffer = nil
        self.activeMaxWidth = 0
    }

    func recoverAfterSystemWake(maxWidth: CGFloat = 1920) async -> Bool {
        await stopCapture()
        contentFilter = nil
        sourceWidth = 0
        sourceHeight = 0
        displayFrame = .zero

        do {
            try await prepareCaptureFilter()
            guard let filter = contentFilter, sourceWidth > 0, sourceHeight > 0 else {
                return false
            }
            let targetWidth = max(1, maxWidth)
            try await rebuildCaptureStream(filter: filter, maxWidth: targetWidth)
            return true
        } catch {
            return false
        }
    }

    func setAudioCaptureSource(_ source: AudioCaptureSource) async {
        guard audioCaptureSource != source else { return }
        audioCaptureSource = source
        if let filter = contentFilter {
            try? await rebuildCaptureStream(filter: filter, maxWidth: activeMaxWidth > 0 ? activeMaxWidth : 1920)
        }
    }

    func setAudioSampleHandler(_ handler: ((CapturedAudioSampleBuffer) -> Void)?) {
        audioSampleHandler = handler
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
                try? stream.removeStreamOutput(streamOutput, type: .audio)
                try? stream.removeStreamOutput(streamOutput, type: .microphone)
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
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        switch audioCaptureSource {
        case .systemOutput:
            config.capturesAudio = true
            config.captureMicrophone = false
        case .microphone:
            config.capturesAudio = false
            config.captureMicrophone = true
        case .systemAndMicrophone:
            config.capturesAudio = true
            config.captureMicrophone = true
        }

        let streamOutput = StreamOutput(owner: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: outputQueue)
        if config.capturesAudio {
            try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: outputQueue)
        }
        if config.captureMicrophone {
            try stream.addStreamOutput(streamOutput, type: .microphone, sampleHandlerQueue: outputQueue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = streamOutput
        self.activeMaxWidth = maxWidth
    }

    fileprivate func consumeFrame(_ pixelBuffer: CapturedPixelBuffer) {
        latestPixelBuffer = pixelBuffer
    }

    fileprivate func consumeAudioSampleBuffer(_ sampleBuffer: CapturedAudioSampleBuffer) {
        audioSampleHandler?(sampleBuffer)
    }
}
private final class StreamOutput: NSObject, SCStreamOutput {
    private weak var owner: MacScreenCaptureProvider?

    init(owner: MacScreenCaptureProvider) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let owner else {
            return
        }

        switch outputType {
        case .screen:
            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            let frame = CapturedPixelBuffer(value: imageBuffer)
            Task {
                await owner.consumeFrame(frame)
            }
        case .audio, .microphone:
            let audioSample = CapturedAudioSampleBuffer(value: sampleBuffer)
            Task {
                await owner.consumeAudioSampleBuffer(audioSample)
            }
        @unknown default:
            return
        }
    }
}
