@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

final class AACAudioEncoder: @unchecked Sendable {
    static let configMarker: UInt8 = 0x20
    static let frameMarker: UInt8 = 0x21

    var onPacket: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "remote.keyboard.aac.encoder")
    private var normalizer: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var normalizedFormat: AVAudioFormat?
    private var aacConverter: AVAudioConverter?
    private var aacFormat: AVAudioFormat?
    private var staging: AVAudioPCMBuffer?
    private var stagedFrames: AVAudioFrameCount = 0
    private var didSendConfig = false
    private var pendingConfigEmission = false
    private let systemMicMixer = SystemMicrophoneMixer()

    private let targetSampleRate: Double = 48_000
    private let targetChannels: AVAudioChannelCount = 2
    private let aacFrameCount: AVAudioFrameCount = 1024
    private let aacBitrate = 160_000

    func encode(sampleBuffer: CMSampleBuffer) {
        let wrapped = SendableSampleBuffer(value: sampleBuffer)
        queue.async {
            self.encodeInternal(wrapped.value)
        }
    }

    func encodeMixed(sampleBuffer: CMSampleBuffer, origin: CapturedAudioOrigin) {
        let wrapped = SendableSampleBuffer(value: sampleBuffer)
        queue.async {
            guard let normalized = self.normalizedBuffer(from: wrapped.value) else { return }
            for mixed in self.systemMicMixer.push(normalized, origin: origin) {
                self.appendAndDrain(mixed)
            }
        }
    }

    func resetMix() {
        queue.async {
            self.systemMicMixer.reset()
        }
    }

    func stop() {
        queue.async {
            self.resetEncoderState()
        }
    }

    func requestStreamResync() {
        queue.async {
            self.pendingConfigEmission = true
        }
    }

    private func encodeInternal(_ sampleBuffer: CMSampleBuffer) {
        guard let normalized = normalizedBuffer(from: sampleBuffer) else { return }
        appendAndDrain(normalized)
    }

    private func normalizedBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbdPointer) else {
            return nil
        }

        if normalizer == nil || inputFormat?.sampleRate != sourceFormat.sampleRate || inputFormat?.channelCount != sourceFormat.channelCount {
            recreateConverter(sourceFormat: sourceFormat)
        }

        guard let normalizer,
              let normalizedFormat,
              let sourcePCM = makeSourcePCMBuffer(from: sampleBuffer, sourceFormat: sourceFormat) else {
            return nil
        }

        let capacity = max(sourcePCM.frameLength, aacFrameCount)
        guard let normalized = AVAudioPCMBuffer(pcmFormat: normalizedFormat, frameCapacity: capacity) else {
            return nil
        }

        var convertError: NSError?
        nonisolated(unsafe) let feed = FeedOnce(buffer: sourcePCM)
        normalizer.convert(to: normalized, error: &convertError) { _, status in
            if feed.didFeed {
                status.pointee = .noDataNow
                return nil
            }
            feed.didFeed = true
            status.pointee = .haveData
            return sourcePCM
        }
        guard convertError == nil, feed.didFeed, normalized.frameLength > 0 else { return nil }
        return normalized
    }

    private func recreateConverter(sourceFormat: AVAudioFormat) {
        resetEncoderState()
        inputFormat = sourceFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ),
        let normalizer = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return
        }

        guard let aacFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVEncoderBitRateKey: aacBitrate
        ]),
        let aacConverter = AVAudioConverter(from: targetFormat, to: aacFormat) else {
            return
        }
        aacConverter.bitRate = aacBitrate

        self.normalizer = normalizer
        self.normalizedFormat = targetFormat
        self.aacFormat = aacFormat
        self.aacConverter = aacConverter
        self.staging = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8_192)
        self.didSendConfig = false
        self.pendingConfigEmission = true
    }

    private func resetEncoderState() {
        normalizer = nil
        inputFormat = nil
        normalizedFormat = nil
        aacConverter = nil
        aacFormat = nil
        staging = nil
        stagedFrames = 0
        didSendConfig = false
        pendingConfigEmission = false
        systemMicMixer.reset()
    }

    private func appendAndDrain(_ buffer: AVAudioPCMBuffer) {
        guard let format = normalizedFormat,
              let staging,
              let destinationChannels = staging.floatChannelData,
              let sourceChannels = buffer.floatChannelData else {
            return
        }

        var incoming = buffer.frameLength
        var sourceOffset = 0
        let channelCount = Int(format.channelCount)
        while incoming > 0 {
            if stagedFrames >= staging.frameCapacity {
                discardOldest(aacFrameCount)
            }
            let room = staging.frameCapacity - stagedFrames
            guard room > 0 else { return }
            let copyCount = min(room, incoming)
            for channel in 0..<channelCount {
                memcpy(
                    destinationChannels[channel].advanced(by: Int(stagedFrames)),
                    sourceChannels[channel].advanced(by: sourceOffset),
                    Int(copyCount) * MemoryLayout<Float>.size
                )
            }
            stagedFrames += copyCount
            staging.frameLength = stagedFrames
            incoming -= copyCount
            sourceOffset += Int(copyCount)
            while stagedFrames >= aacFrameCount {
                encodeOneAACPacket()
            }
        }
    }

    private func discardOldest(_ count: AVAudioFrameCount) {
        guard let staging, let channels = staging.floatChannelData else { return }
        let drop = min(count, stagedFrames)
        let remain = stagedFrames - drop
        let channelCount = Int(staging.format.channelCount)
        if remain > 0 {
            for channel in 0..<channelCount {
                memmove(
                    channels[channel],
                    channels[channel].advanced(by: Int(drop)),
                    Int(remain) * MemoryLayout<Float>.size
                )
            }
        }
        stagedFrames = remain
        staging.frameLength = remain
    }

    private func encodeOneAACPacket() {
        guard let staging,
              let format = normalizedFormat,
              let aacConverter,
              let aacFormat,
              let sourceChannels = staging.floatChannelData,
              let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: aacFrameCount),
              let sliceChannels = slice.floatChannelData else {
            return
        }

        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            memcpy(sliceChannels[channel], sourceChannels[channel], Int(aacFrameCount) * MemoryLayout<Float>.size)
        }
        slice.frameLength = aacFrameCount
        discardOldest(aacFrameCount)

        let compressed = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: 8,
            maximumPacketSize: 2_048
        )
        nonisolated(unsafe) let feed = FeedOnce(buffer: slice)
        var error: NSError?
        aacConverter.convert(to: compressed, error: &error) { _, status in
            if feed.didFeed {
                status.pointee = .noDataNow
                return nil
            }
            feed.didFeed = true
            status.pointee = .haveData
            return slice
        }
        guard error == nil, compressed.packetCount > 0, let descriptions = compressed.packetDescriptions else {
            return
        }

        if didSendConfig == false || pendingConfigEmission {
            emitConfigPacket()
            didSendConfig = true
            pendingConfigEmission = false
        }

        let packetCount = Int(compressed.packetCount)
        for index in 0..<packetCount {
            let description = descriptions[index]
            let start = Int(description.mStartOffset)
            let size = Int(description.mDataByteSize)
            guard size > 0, start >= 0, start + size <= Int(compressed.byteLength) else { continue }
            let bytes = Data(bytes: compressed.data.advanced(by: start), count: size)
            emitFramePacket(bytes)
        }
    }

    private func emitConfigPacket() {
        let asc = audioSpecificConfig(sampleRate: Int(targetSampleRate), channels: Int(targetChannels))
        var packet = Data([Self.configMarker])
        packet.append(contentsOf: "AAC1".utf8)
        packet.appendUInt32BE(UInt32(targetSampleRate))
        packet.appendUInt16BE(UInt16(targetChannels))
        packet.appendUInt16BE(UInt16(asc.count))
        packet.append(asc)
        onPacket?(packet)
    }

    private func emitFramePacket(_ aacBytes: Data) {
        guard aacBytes.isEmpty == false else { return }
        var packet = Data([Self.frameMarker])
        packet.appendUInt32BE(UInt32(aacBytes.count))
        packet.append(aacBytes)
        onPacket?(packet)
    }

    private func audioSpecificConfig(sampleRate: Int, channels: Int) -> Data {
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        let frequencyIndex = rates.firstIndex(of: sampleRate) ?? 3
        let objectType = 2
        let bits = (objectType << 11) | (frequencyIndex << 7) | (channels << 3)
        return Data([UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
    }

    private func makeSourcePCMBuffer(from sampleBuffer: CMSampleBuffer, sourceFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcmBuffer
    }
}

private final class SystemMicrophoneMixer {
    private var systemSamples: [Float] = []
    private var microphoneSamples: [Float] = []
    private let channels = 2
    private let emitFrames = 1024
    private let maxLeadFrames = 4_800

    func reset() {
        systemSamples.removeAll(keepingCapacity: true)
        microphoneSamples.removeAll(keepingCapacity: true)
    }

    func push(_ buffer: AVAudioPCMBuffer, origin: CapturedAudioOrigin) -> [AVAudioPCMBuffer] {
        guard let interleaved = interleavedStereo(from: buffer) else { return [] }
        switch origin {
        case .systemOutput:
            systemSamples.append(contentsOf: interleaved)
        case .microphone:
            microphoneSamples.append(contentsOf: interleaved)
        }
        return drain(format: buffer.format)
    }

    private func drain(format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        var emitted: [AVAudioPCMBuffer] = []
        var guardrail = 0
        while guardrail < 8 {
            guardrail += 1
            let systemFrames = systemSamples.count / channels
            let microphoneFrames = microphoneSamples.count / channels
            if min(systemFrames, microphoneFrames) >= emitFrames {
                guard let mixed = mix(frameCount: emitFrames, format: format) else { break }
                emitted.append(mixed)
                continue
            }
            let lead = abs(systemFrames - microphoneFrames)
            if lead >= maxLeadFrames, max(systemFrames, microphoneFrames) > 0 {
                let fill = min(emitFrames, lead)
                let zeros = [Float](repeating: 0, count: fill * channels)
                if systemFrames < microphoneFrames {
                    systemSamples.append(contentsOf: zeros)
                } else {
                    microphoneSamples.append(contentsOf: zeros)
                }
                continue
            }
            break
        }
        let cap = 48_000 * 2 * channels
        if systemSamples.count > cap {
            systemSamples.removeFirst(systemSamples.count - cap)
        }
        if microphoneSamples.count > cap {
            microphoneSamples.removeFirst(microphoneSamples.count - cap)
        }
        return emitted
    }

    private func mix(frameCount: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleCount = frameCount * channels
        guard systemSamples.count >= sampleCount, microphoneSamples.count >= sampleCount else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else {
            return nil
        }
        let channelCount = min(Int(format.channelCount), channels)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = frame * channels + channel
                let mixed = systemSamples[index] + microphoneSamples[index]
                channelData[channel][frame] = max(-1, min(1, mixed))
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        systemSamples.removeFirst(sampleCount)
        microphoneSamples.removeFirst(sampleCount)
        return buffer
    }

    private func interleavedStereo(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let source = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var output: [Float] = []
        output.reserveCapacity(frames * channels)
        let sourceChannels = Int(buffer.format.channelCount)
        if sourceChannels <= 1 {
            for frame in 0..<frames {
                let sample = source[0][frame]
                output.append(sample)
                output.append(sample)
            }
        } else {
            for frame in 0..<frames {
                output.append(source[0][frame])
                output.append(source[1][frame])
            }
        }
        return output
    }
}

private final class FeedOnce: @unchecked Sendable {
    var didFeed = false
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        var big = value.bigEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &big, Array.init))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var big = value.bigEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &big, Array.init))
    }
}
