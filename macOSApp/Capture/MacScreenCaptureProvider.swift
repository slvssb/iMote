import AppKit
import AVFoundation
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
    private var activeDisplayID: CGDirectDisplayID?
    private var preferredPrimaryDisplayID: CGDirectDisplayID?
    private var sourceWidth: CGFloat = 0
    private var sourceHeight: CGFloat = 0
    private var displayFrame: CGRect = .zero
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private let outputQueue = DispatchQueue(label: "remote.keyboard.capture.output")
    private var latestPixelBuffer: CapturedPixelBuffer?
    private var activeMaxWidth: CGFloat = 0
    private var audioCaptureSource: AudioCaptureSource = .off
    private let audioMixer = SystemAndMicMixer()
    private var audioSampleHandler: ((CapturedAudioSampleBuffer) -> Void)?
    private var activeCaptureRouteLabel: String = "Unknown"
    private var preferFallbackDisplay = false
    private var captureEnabled = true

    func resumeCaptureForPairedClient() {
        captureEnabled = true
    }

    func suspendForIdleClients() async {
        captureEnabled = false
        audioCaptureSource = .off
        await stopCapture()
    }

    func makeFramePixelBuffer(maxWidth: CGFloat = 1920) async -> CapturedPixelBuffer? {
        guard captureEnabled else { return nil }
        do {
            if contentFilter == nil {
                try await prepareCaptureFilter()
            }
            guard captureEnabled else { return nil }

            guard let filter = contentFilter,
                  sourceWidth > 0,
                  sourceHeight > 0 else {
                return nil
            }

            try await ensureCaptureStream(filter: filter, maxWidth: maxWidth)
            guard captureEnabled else {
                await stopCapture()
                return nil
            }
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
        self.activeDisplayID = nil
        self.activeCaptureRouteLabel = "Unknown"
        self.latestPixelBuffer = nil
        self.activeMaxWidth = 0
        audioMixer.reset()
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
        audioMixer.reset()
        if let filter = contentFilter {
            try? await rebuildCaptureStream(filter: filter, maxWidth: activeMaxWidth > 0 ? activeMaxWidth : 1920)
        }
    }

    func setAudioSampleHandler(_ handler: ((CapturedAudioSampleBuffer) -> Void)?) {
        audioSampleHandler = handler
    }

    func normalizedCursorPosition() async -> CGPoint? {
        let frame = displayFrame
        guard frame.isEmpty == false else { return nil }

        let location = await MainActor.run { NSEvent.mouseLocation }
        let relativeX = (location.x - frame.minX) / frame.width
        let relativeY = (location.y - frame.minY) / frame.height

        let clampedX = min(max(relativeX, 0), 1)
        let clampedY = min(max(1 - relativeY, 0), 1)
        return CGPoint(x: clampedX, y: clampedY)
    }

    func currentCaptureRouteLabel() -> String {
        activeCaptureRouteLabel
    }

    func setPreferFallbackDisplay(_ enabled: Bool) {
        preferFallbackDisplay = enabled
    }

    private func prepareCaptureFilter() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = selectCaptureDisplay(from: content.displays) else {
            activeDisplayID = nil
            activeCaptureRouteLabel = "Unknown"
            return
        }

        sourceWidth = CGFloat(display.width)
        sourceHeight = CGFloat(display.height)
        displayFrame = display.frame
        activeDisplayID = display.displayID
        if preferFallbackDisplay == false {
            // Remember the display we are actively mirroring while the real monitor path is healthy.
            preferredPrimaryDisplayID = display.displayID
        }
        activeCaptureRouteLabel = resolveCaptureRouteLabel(
            selectedDisplayID: display.displayID,
            displayCount: content.displays.count
        )
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
        case .off:
            config.capturesAudio = false
            config.captureMicrophone = false
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

    fileprivate func consumeAudioSampleBuffer(
        _ sampleBuffer: CapturedAudioSampleBuffer,
        from outputType: SCStreamOutputType
    ) {
        guard audioCaptureSource == .systemAndMicrophone else {
            audioSampleHandler?(sampleBuffer)
            return
        }
        let mixed = audioMixer.push(sampleBuffer.value, isMicrophone: outputType == .microphone)
        for buffer in mixed {
            audioSampleHandler?(CapturedAudioSampleBuffer(value: buffer))
        }
    }

    private func selectCaptureDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        guard displays.isEmpty == false else { return nil }

        if preferFallbackDisplay {
            if let preferredPrimaryDisplayID {
                let fallbackDisplays = displays.filter { $0.displayID != preferredPrimaryDisplayID }
                if let fallback = fallbackDisplays.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) {
                    return fallback
                }
            }

            return displays.max { lhs, rhs in
                (lhs.width * lhs.height) < (rhs.width * rhs.height)
            }
        }

        if let preferredPrimaryDisplayID,
           let preferredDisplay = displays.first(where: { $0.displayID == preferredPrimaryDisplayID }) {
            return preferredDisplay
        }

        if let mainDisplay = displays.first(where: { $0.displayID == CGMainDisplayID() }) {
            preferredPrimaryDisplayID = mainDisplay.displayID
            return mainDisplay
        }

        return displays.max { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
        }
    }

    private func resolveCaptureRouteLabel(selectedDisplayID: CGDirectDisplayID, displayCount: Int) -> String {
        if let preferredPrimaryDisplayID {
            return selectedDisplayID == preferredPrimaryDisplayID ? "Real" : "Dummy/Fallback"
        }

        if displayCount > 1 {
            return selectedDisplayID == CGMainDisplayID() ? "Real" : "Dummy/Fallback"
        }

        return "Real"
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
            let outputType = outputType
            Task {
                await owner.consumeAudioSampleBuffer(audioSample, from: outputType)
            }
        @unknown default:
            return
        }
    }
}

/// ScreenCaptureKit delivers system audio and the microphone as separate buffers.
/// Both mode used to encode each buffer on its own, so the phone heard them alternating.
/// This mixes matching frames into one PCM buffer before the AAC encoder packetizes it.
private final class SystemAndMicMixer {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )
    private var systemConverter: AVAudioConverter?
    private var systemFormatKey: String?
    private var microphoneConverter: AVAudioConverter?
    private var microphoneFormatKey: String?
    private var systemSamples: [Float] = []
    private var microphoneSamples: [Float] = []
    private var sawSystem = false
    private var sawMicrophone = false

    func reset() {
        systemConverter = nil
        systemFormatKey = nil
        microphoneConverter = nil
        microphoneFormatKey = nil
        systemSamples.removeAll()
        microphoneSamples.removeAll()
        sawSystem = false
        sawMicrophone = false
    }

    func push(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) -> [CMSampleBuffer] {
        guard let targetFormat,
              let converted = convert(sampleBuffer, isMicrophone: isMicrophone, targetFormat: targetFormat) else {
            return []
        }
        if isMicrophone {
            microphoneSamples.append(contentsOf: converted)
            sawMicrophone = true
        } else {
            systemSamples.append(contentsOf: converted)
            sawSystem = true
        }
        trimLead()
        return drain(format: targetFormat)
    }

    private func drain(format: AVAudioFormat) -> [CMSampleBuffer] {
        let systemFrames = systemSamples.count / 2
        let microphoneFrames = microphoneSamples.count / 2

        if sawSystem && sawMicrophone {
            let frames = min(systemFrames, microphoneFrames)
            guard frames > 0 else { return [] }
            var mixed = [Float](repeating: 0, count: frames * 2)
            for index in 0..<(frames * 2) {
                let sum = systemSamples[index] + microphoneSamples[index]
                mixed[index] = min(1, max(-1, sum))
            }
            systemSamples.removeFirst(frames * 2)
            microphoneSamples.removeFirst(frames * 2)
            guard let buffer = makeSampleBuffer(samples: mixed, format: format) else { return [] }
            return [buffer]
        }

        // Hold a lone stream briefly so the other side can arrive, then pass it through.
        let soloHoldFrames = 48_000 / 10
        if sawMicrophone == false, systemFrames >= soloHoldFrames {
            return emitSolo(&systemSamples, frames: systemFrames, format: format)
        }
        if sawSystem == false, microphoneFrames >= soloHoldFrames {
            return emitSolo(&microphoneSamples, frames: microphoneFrames, format: format)
        }
        return []
    }

    private func emitSolo(_ samples: inout [Float], frames: Int, format: AVAudioFormat) -> [CMSampleBuffer] {
        let count = frames * 2
        let chunk = Array(samples.prefix(count))
        samples.removeFirst(count)
        guard let buffer = makeSampleBuffer(samples: chunk, format: format) else { return [] }
        return [buffer]
    }

    private func trimLead() {
        let maxSamples = 48_000 * 2 * 2
        if systemSamples.count > maxSamples {
            systemSamples.removeFirst(systemSamples.count - maxSamples)
        }
        if microphoneSamples.count > maxSamples {
            microphoneSamples.removeFirst(microphoneSamples.count - maxSamples)
        }
    }

    private func convert(
        _ sampleBuffer: CMSampleBuffer,
        isMicrophone: Bool,
        targetFormat: AVAudioFormat
    ) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbdPointer) else {
            return nil
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let key = "\(sourceFormat.sampleRate)-\(sourceFormat.channelCount)-\(sourceFormat.commonFormat.rawValue)"
        let converter: AVAudioConverter
        if isMicrophone {
            if microphoneConverter == nil || microphoneFormatKey != key {
                guard let created = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
                microphoneConverter = created
                microphoneFormatKey = key
            }
            guard let microphoneConverter else { return nil }
            converter = microphoneConverter
        } else {
            if systemConverter == nil || systemFormatKey != key {
                guard let created = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return nil }
                systemConverter = created
                systemFormatKey = key
            }
            guard let systemConverter else { return nil }
            converter = systemConverter
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
            return nil
        }
        var convertError: NSError?
        let feed = MixerFeed(buffer: sourceBuffer)
        converter.convert(to: output, error: &convertError) { _, status in
            if feed.didFeed {
                status.pointee = .noDataNow
                return nil
            }
            feed.didFeed = true
            status.pointee = .haveData
            return sourceBuffer
        }
        guard convertError == nil, output.frameLength > 0 else { return nil }
        let frames = Int(output.frameLength)
        let channels = Int(output.format.channelCount)
        let sampleCount = frames * channels
        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else { return nil }
        let pointer = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: sampleCount))
    }

    private func makeSampleBuffer(samples: [Float], format: AVAudioFormat) -> CMSampleBuffer? {
        guard samples.count >= 2, samples.count.isMultiple(of: 2) else { return nil }
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else {
            return nil
        }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(asbd.mBytesPerFrame)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: samples.count / 2,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr else { return nil }
        return sample
    }
}

private final class MixerFeed: @unchecked Sendable {
    var didFeed = false
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
