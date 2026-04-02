import CoreMedia
import CoreVideo
import Foundation
import UIKit
import VideoToolbox

final class H264FrameDecoder {
    var onImage: ((UIImage) -> Void)?

    private var formatDescription: CMFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var frameIndex: Int64 = 0

    func configure(with configPayload: Data) {
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
            }
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

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
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

        frameIndex += 1

        let flags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
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

    fileprivate func emitImage(_ image: UIImage) {
        onImage?(image)
    }
}

private let decompressionOutputCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, _, _ in
    guard status == noErr,
          let refCon,
          let imageBuffer else {
        return
    }

    var cgImage: CGImage?
    let cgStatus = VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
    guard cgStatus == noErr, let cgImage else {
        return
    }

    let image = UIImage(cgImage: cgImage)
    let decoder = Unmanaged<H264FrameDecoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.emitImage(image)
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
