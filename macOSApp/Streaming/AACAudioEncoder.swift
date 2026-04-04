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

    private let queue = DispatchQueue(label: "remote.keyboard.pcm.encoder")
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var didSendConfig = false
    private var pendingConfigEmission = false

    func encode(sampleBuffer: CMSampleBuffer) {
        let wrapped = SendableSampleBuffer(value: sampleBuffer)
        queue.async {
            self.encodeInternal(wrapped.value)
        }
    }

    func stop() {
        queue.async {
            self.converter = nil
            self.inputFormat = nil
            self.outputFormat = nil
            self.didSendConfig = false
            self.pendingConfigEmission = false
        }
    }

    func requestStreamResync() {
        queue.async {
            self.pendingConfigEmission = true
        }
    }

    private func encodeInternal(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbdPointer) else {
            return
        }

        if converter == nil || inputFormat?.sampleRate != sourceFormat.sampleRate || inputFormat?.channelCount != sourceFormat.channelCount {
            recreateConverter(sourceFormat: sourceFormat)
        }

        guard let converter,
              let outputFormat,
              let sourcePCM = makeSourcePCMBuffer(from: sampleBuffer, sourceFormat: sourceFormat),
              let normalizedPCM = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: sourcePCM.frameLength) else {
            return
        }

        do {
            try converter.convert(to: normalizedPCM, from: sourcePCM)
        } catch {
            return
        }

        guard normalizedPCM.frameLength > 0 else {
            return
        }

        if didSendConfig == false || pendingConfigEmission {
            emitConfigPacket(sampleRate: outputFormat.sampleRate, channels: outputFormat.channelCount)
            didSendConfig = true
            pendingConfigEmission = false
        }

        emitFramePacket(normalizedPCM)
    }

    private func recreateConverter(sourceFormat: AVAudioFormat) {
        inputFormat = sourceFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            self.converter = nil
            self.outputFormat = nil
            return
        }

        self.converter = converter
        self.outputFormat = targetFormat
        self.didSendConfig = false
        self.pendingConfigEmission = true
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

        guard status == noErr else {
            return nil
        }

        return pcmBuffer
    }

    private func emitConfigPacket(sampleRate: Double, channels: AVAudioChannelCount) {
        let sr = UInt32(sampleRate.rounded())
        let ch = UInt8(min(channels, AVAudioChannelCount(UInt8.max)))

        var packet = Data([Self.configMarker])
        packet.append(contentsOf: withUnsafeBytes(of: sr.bigEndian, Array.init))
        packet.append(ch)
        onPacket?(packet)
    }

    private func emitFramePacket(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var packet = Data([Self.frameMarker])
        let frameCountBE = UInt32(frameCount).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: frameCountBE, Array.init))
        packet.append(UInt8(min(channelCount, Int(UInt8.max))))

        let bytesPerChannel = frameCount * MemoryLayout<Float>.size
        for channel in 0..<channelCount {
            let byteCountBE = UInt32(bytesPerChannel).bigEndian
            packet.append(contentsOf: withUnsafeBytes(of: byteCountBE, Array.init))
            let data = Data(bytes: channelData[channel], count: bytesPerChannel)
            packet.append(data)
        }

        onPacket?(packet)
    }
}
