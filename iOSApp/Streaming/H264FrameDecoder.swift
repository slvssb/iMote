import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264FrameDecoder {
    private static let targetFPS = 60

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onDecodeLatency: ((Double) -> Void)?

    private var formatDescription: CMFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var lastConfigPayload: Data?
    private var frameIndex: Int64 = 0
    private var decodeStartByFrameIndex: [Int64: CFAbsoluteTime] = [:]
    private let decodeStateLock = NSLock()

    func configure(with configPayload: Data) {
        lastConfigPayload = configPayload
        guard let (sps, pps) = parseConfigPayload(configPayload) else {
            return
        }

        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                let parameterSetPointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                let parameterSetSizes: [Int] = [sps.count, pps.count]

                var formatDescriptionOut: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescriptionOut
                )

                guard status == noErr, let formatDescriptionOut else {
                    return
                }

                self.formatDescription = formatDescriptionOut
                self.recreateDecompressionSession(formatDescriptionOut)
                self.frameIndex = 0
                self.decodeStateLock.lock()
                self.decodeStartByFrameIndex.removeAll()
                self.decodeStateLock.unlock()
            }
        }
    }

    func forceResyncUsingLastConfig() {
        guard let lastConfigPayload else { return }
        configure(with: lastConfigPayload)
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

    private func parseConfigPayload(_ data: Data) -> (Data, Data)? {
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

        return (sps, pps)
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
        if decodeStartByFrameIndex.count > 8 {
            let stale = decodeStartByFrameIndex.keys.filter { $0 < index - 8 }
            for key in stale {
                decodeStartByFrameIndex.removeValue(forKey: key)
            }
        }
        if decodeStartByFrameIndex.count > 16 {
            let overflow = decodeStartByFrameIndex.keys.sorted().dropLast(8)
            for key in overflow {
                decodeStartByFrameIndex.removeValue(forKey: key)
            }
        }
        decodeStateLock.unlock()
    }

    fileprivate func clearFrameDecodeStart(index: Int64) {
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
    guard let refCon else { return }
    let decoder = Unmanaged<H264FrameDecoder>.fromOpaque(refCon).takeUnretainedValue()
    guard status == noErr, let imageBuffer else {
        if presentationTimeStamp.isValid {
            decoder.clearFrameDecodeStart(index: presentationTimeStamp.value)
        }
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
        if presentationTimeStamp.isValid {
            decoder.clearFrameDecodeStart(index: presentationTimeStamp.value)
        }
        return
    }

    let outputPTS: CMTime
    if presentationTimeStamp.isValid {
        outputPTS = presentationTimeStamp
    } else {
        // AVSampleBufferDisplayLayer is more reliable with concrete timing than `.invalid`.
        outputPTS = CMClockGetTime(CMClockGetHostTimeClock())
    }
    var timingInfo = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: outputPTS,
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
        if presentationTimeStamp.isValid {
            decoder.clearFrameDecodeStart(index: presentationTimeStamp.value)
        }
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
