import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private struct EncoderPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

final class H264FrameEncoder: @unchecked Sendable {
    private static let targetFPS = 60
    private static let minAdaptiveScale = 0.45
    private static let maxAdaptiveScale = 1.0

    struct QualityProfile: @unchecked Sendable {
        let profileLevel: CFString
        let bitsPerPixel: Double
        let minBitrate: Int
        let maxBitrate: Int
        let keyframeInterval: Int

        static let balanced = QualityProfile(
            profileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            bitsPerPixel: 0.14,
            minBitrate: 8_000_000,
            maxBitrate: 20_000_000,
            keyframeInterval: 45
        )

        static let ultra = QualityProfile(
            profileLevel: kVTProfileLevel_H264_High_AutoLevel,
            bitsPerPixel: 0.23,
            minBitrate: 12_000_000,
            maxBitrate: 35_000_000,
            keyframeInterval: 30
        )
    }

    static let configMarker: UInt8 = 0x10
    static let frameMarker: UInt8 = 0x11

    var onPacket: ((Data) -> Void)?

    private var compressionSession: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameIndex: Int64 = 0
    private var didSendConfig = false
    private var qualityProfile: QualityProfile = .ultra
    private var adaptiveBitrateScale: Double = 1.0

    private let queue = DispatchQueue(label: "remote.keyboard.h264.encoder")

    func encode(cgImage: CGImage) {
        queue.async {
            self.encodeInternal(cgImage)
        }
    }

    func encode(pixelBuffer: CVPixelBuffer) {
        let sendableBuffer = EncoderPixelBuffer(value: pixelBuffer)
        queue.async {
            self.encodeInternal(sendableBuffer.value)
        }
    }

    func stop() {
        queue.async {
            if let session = self.compressionSession {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
                self.compressionSession = nil
            }
            self.didSendConfig = false
            self.frameIndex = 0
        }
    }

    func setQualityProfile(_ profile: QualityProfile) {
        queue.async {
            self.qualityProfile = profile
            if self.width > 0, self.height > 0 {
                self.recreateSession(width: self.width, height: self.height)
            }
        }
    }

    func setAdaptiveBitrateScale(_ scale: Double) {
        queue.async {
            let clamped = min(max(scale, Self.minAdaptiveScale), Self.maxAdaptiveScale)
            self.adaptiveBitrateScale = clamped
            guard let session = self.compressionSession,
                  self.width > 0,
                  self.height > 0 else {
                return
            }
            self.applyBitrate(to: session, width: self.width, height: self.height)
        }
    }

    private func encodeInternal(_ cgImage: CGImage) {
        let nextWidth = Int32(cgImage.width)
        let nextHeight = Int32(cgImage.height)

        if compressionSession == nil || nextWidth != width || nextHeight != height {
            recreateSession(width: nextWidth, height: nextHeight)
        }

        guard let session = compressionSession,
              let pixelBuffer = makePixelBuffer(from: cgImage) else {
            return
        }

        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(Self.targetFPS))
        frameIndex += 1

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func encodeInternal(_ pixelBuffer: CVPixelBuffer) {
        let nextWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let nextHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))

        if compressionSession == nil || nextWidth != width || nextHeight != height {
            recreateSession(width: nextWidth, height: nextHeight)
        }

        guard let session = compressionSession else {
            return
        }

        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(Self.targetFPS))
        frameIndex += 1

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func recreateSession(width: Int32, height: Int32) {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        self.width = width
        self.height = height
        self.didSendConfig = false
        self.frameIndex = 0

        var session: VTCompressionSession?
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: qualityProfile.profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        let targetFPS = Self.targetFPS
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFPS as CFTypeRef)

        applyBitrate(to: session, width: width, height: height)

        let keyframeInterval = qualityProfile.keyframeInterval as CFTypeRef
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFTypeRef)

        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
    }

    private func targetBitrate(width: Int32, height: Int32, fps: Int) -> Int {
        let pixelRate = Int(width * height) * fps
        let estimated = Int(Double(pixelRate) * qualityProfile.bitsPerPixel)
        let clamped = min(max(estimated, qualityProfile.minBitrate), qualityProfile.maxBitrate)
        let scaled = Int(Double(clamped) * adaptiveBitrateScale)
        return min(max(scaled, qualityProfile.minBitrate / 2), qualityProfile.maxBitrate)
    }

    private func applyBitrate(to session: VTCompressionSession, width: Int32, height: Int32) {
        let bitrate = targetBitrate(width: width, height: height, fps: Self.targetFPS)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
    }

    private func makePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: cgImage.width,
            kCVPixelBufferHeightKey: cgImage.height
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            cgImage.width,
            cgImage.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: baseAddress,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return pixelBuffer
    }

    fileprivate func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if didSendConfig == false,
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            emitConfigPacket(formatDescription)
            didSendConfig = true
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr,
              let dataPointer,
              totalLength > 0 else {
            return
        }

        var packet = Data([Self.frameMarker])
        packet.append(Data(bytes: dataPointer, count: totalLength))
        onPacket?(packet)
    }

    private func emitConfigPacket(_ formatDescription: CMFormatDescription) {
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        var spsCount = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        var ppsCount = 0

        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsLength,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )

        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsLength,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer,
              spsCount > 0,
              ppsCount > 0,
              spsLength > 0,
              ppsLength > 0 else {
            return
        }

        var packet = Data([Self.configMarker])
        packet.append(contentsOf: withUnsafeBytes(of: UInt16(spsLength).bigEndian, Array.init))
        packet.append(Data(bytes: spsPointer, count: spsLength))
        packet.append(contentsOf: withUnsafeBytes(of: UInt16(ppsLength).bigEndian, Array.init))
        packet.append(Data(bytes: ppsPointer, count: ppsLength))
        onPacket?(packet)
    }
}

private let compressionOutputCallback: VTCompressionOutputCallback = { refCon, _, status, _, sampleBuffer in
    guard status == noErr,
          let refCon,
          let sampleBuffer else {
        return
    }

    let encoder = Unmanaged<H264FrameEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedSampleBuffer(sampleBuffer)
}
