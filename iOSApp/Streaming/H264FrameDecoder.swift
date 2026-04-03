import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264FrameDecoder {
    private static let targetFPS = 60

    private enum ConfigCodecTag: UInt8 {
        case h264 = 0x01
        case hevc = 0x02
    }

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onDecodeLatency: ((Double) -> Void)?

    private var formatDescription: CMFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var frameIndex: Int64 = 0
    private var decodeStartByFrameIndex: [Int64: CFAbsoluteTime] = [:]
    private let decodeStateLock = NSLock()

    func configure(with configPayload: Data) {
        guard configPayload.isEmpty == false else { return }

        if let tagged = parseTaggedConfigPayload(configPayload),
           let formatDescription = makeFormatDescription(for: tagged.codec, parameterSets: tagged.parameterSets) {
            applyFormatDescription(formatDescription)
            return
        }

        if let legacy = parseLegacyH264ConfigPayload(configPayload),
           let formatDescription = makeFormatDescription(for: .h264, parameterSets: legacy) {
            applyFormatDescription(formatDescription)
        }
    }

    func decode(framePayload: Data) {
        guard let formatDescription,
              let decompressionSession else {
            return
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: framePayload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: framePayload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr,
              let blockBuffer else {
            return
        }

        framePayload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: framePayload.count
            )
        }

        let currentFrameIndex = frameIndex
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: currentFrameIndex, timescale: CMTimeScale(Self.targetFPS)),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [framePayload.count]
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr,
              let sampleBuffer else {
            return
        }

        markFrameDecodeStart(index: currentFrameIndex)
        frameIndex += 1

        let flags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if decodeStatus != noErr {
            clearFrameDecodeStart(index: currentFrameIndex)
        }
    }

    private func recreateDecompressionSession(_ formatDescription: CMFormatDescription) {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &sessionOut
        )

        if status == noErr {
            decompressionSession = sessionOut
        }
    }

    private func parseTaggedConfigPayload(_ data: Data) -> (codec: ConfigCodecTag, parameterSets: [Data])? {
        guard let codecTag = data.first.flatMap({ ConfigCodecTag(rawValue: $0) }) else {
            return nil
        }

        let expectedSetCount: Int
        switch codecTag {
        case .h264:
            expectedSetCount = 2
        case .hevc:
            expectedSetCount = 3
        }

        var offset = 1
        var parameterSets: [Data] = []
        for _ in 0..<expectedSetCount {
            guard offset + 2 <= data.count else { return nil }
            let length = Int(data.readUInt16(at: &offset))
            guard length > 0, offset + length <= data.count else { return nil }
            parameterSets.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }

        return (codecTag, parameterSets)
    }

    private func parseLegacyH264ConfigPayload(_ data: Data) -> [Data]? {
        guard data.count >= 4 else { return nil }

        var offset = 0
        let spsLength = Int(data.readUInt16(at: &offset))
        guard spsLength > 0, offset + spsLength <= data.count else { return nil }
        let sps = data.subdata(in: offset..<(offset + spsLength))
        offset += spsLength

        guard offset + 2 <= data.count else { return nil }
        let ppsLength = Int(data.readUInt16(at: &offset))
        guard ppsLength > 0, offset + ppsLength <= data.count else { return nil }
        let pps = data.subdata(in: offset..<(offset + ppsLength))

        return [sps, pps]
    }

    private func makeFormatDescription(for codec: ConfigCodecTag, parameterSets: [Data]) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?

        switch codec {
        case .h264:
            guard parameterSets.count >= 2 else { return nil }
            return parameterSets[0].withUnsafeBytes { spsBytes in
                parameterSets[1].withUnsafeBytes { ppsBytes in
                    guard let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return nil
                    }

                    let pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                    let sizes: [Int] = [parameterSets[0].count, parameterSets[1].count]

                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                    return status == noErr ? formatDescription : nil
                }
            }
        case .hevc:
            guard parameterSets.count >= 3 else { return nil }
            return parameterSets[0].withUnsafeBytes { vpsBytes in
                parameterSets[1].withUnsafeBytes { spsBytes in
                    parameterSets[2].withUnsafeBytes { ppsBytes in
                        guard let vpsPointer = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return nil
                        }

                        let pointers: [UnsafePointer<UInt8>] = [vpsPointer, spsPointer, ppsPointer]
                        let sizes: [Int] = [parameterSets[0].count, parameterSets[1].count, parameterSets[2].count]

                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: pointers,
                            parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &formatDescription
                        )
                        return status == noErr ? formatDescription : nil
                    }
                }
            }
        }
    }

    private func applyFormatDescription(_ formatDescription: CMFormatDescription) {
        self.formatDescription = formatDescription
        recreateDecompressionSession(formatDescription)
        frameIndex = 0
        decodeStateLock.lock()
        decodeStartByFrameIndex.removeAll()
        decodeStateLock.unlock()
    }

    fileprivate func emitSampleBuffer(_ sampleBuffer: CMSampleBuffer, frameIndex: Int64?) {
        if let frameIndex,
           let latencyMs = consumeFrameDecodeLatency(index: frameIndex) {
            onDecodeLatency?(latencyMs)
        }
        onSampleBuffer?(sampleBuffer)
    }

    private func markFrameDecodeStart(index: Int64) {
        decodeStateLock.lock()
        decodeStartByFrameIndex[index] = CFAbsoluteTimeGetCurrent()
        decodeStateLock.unlock()
    }

    private func clearFrameDecodeStart(index: Int64) {
        decodeStateLock.lock()
        decodeStartByFrameIndex.removeValue(forKey: index)
        decodeStateLock.unlock()
    }

    private func consumeFrameDecodeLatency(index: Int64) -> Double? {
        decodeStateLock.lock()
        let startedAt = decodeStartByFrameIndex.removeValue(forKey: index)
        decodeStateLock.unlock()
        guard let startedAt else { return nil }
        return (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
    }
}

private let decompressionOutputCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, presentationTimeStamp, _ in
    guard status == noErr,
          let refCon,
          let imageBuffer else {
        return
    }

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr,
          let formatDescription else {
        return
    }

    var timingInfo = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: .invalid,
        decodeTimeStamp: .invalid
    )
    var outputSampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timingInfo,
        sampleBufferOut: &outputSampleBuffer
    )
    guard sampleStatus == noErr,
          let outputSampleBuffer else {
        return
    }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(outputSampleBuffer, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
        let dictionaryPointer = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(dictionaryPointer, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    let decoder = Unmanaged<H264FrameDecoder>.fromOpaque(refCon).takeUnretainedValue()
    let outputFrameIndex = presentationTimeStamp.isValid ? presentationTimeStamp.value : nil
    decoder.emitSampleBuffer(outputSampleBuffer, frameIndex: outputFrameIndex)
}

private extension Data {
    func readUInt16(at offset: inout Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        let high = UInt16(self[offset])
        let low = UInt16(self[offset + 1])
        offset += 2
        return (high << 8) | low
    }
}
