@preconcurrency import AVFoundation
import Foundation

final class AACAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "remote.keyboard.pcm.player")
    private let minPendingBuffersBeforePlay = 4
    private let maxPendingBuffers = 16

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var outputFormat: AVAudioFormat?
    private var aacFormat: AVAudioFormat?
    private var aacDecoder: AVAudioConverter?
    private var isStarted = false
    private var pendingBufferCount = 0
    private var hasStartedPlayback = false
    private var audioDebugScheduledFrameCount = 0
    private var audioDebugDroppedFrameCount = 0

    init() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
    }

    func start() {
        queue.async {
            self.startInternal()
        }
    }

    func stop() {
        queue.async {
            self.stopInternal()
        }
    }

    func configure(with payload: Data) {
        queue.async {
            self.configureInternal(payload)
        }
    }

    func enqueueFrame(_ payload: Data) {
        queue.async {
            self.enqueueFrameInternal(payload)
        }
    }

    private func startInternal() {
        guard isStarted == false else { return }
        configureAudioSession()
        do {
            try audioEngine.start()
            isStarted = true
        } catch {
            stopInternal()
        }
    }

    private func stopInternal() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        playerNode.reset()
        audioEngine.stop()
        outputFormat = nil
        aacFormat = nil
        aacDecoder = nil
        isStarted = false
        pendingBufferCount = 0
        hasStartedPlayback = false
        audioDebugScheduledFrameCount = 0
        audioDebugDroppedFrameCount = 0
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            return
        }
    }

    private func configureInternal(_ payload: Data) {
        guard payload.count >= 12 else { return }
        guard payload.prefix(4).elementsEqual("AAC1".utf8) else { return }

        var offset = 4
        let sampleRateRaw = payload.readUInt32(at: &offset)
        let channelCountRaw = Int(payload.readUInt16(at: &offset))
        let ascLength = Int(payload.readUInt16(at: &offset))
        guard sampleRateRaw > 0,
              channelCountRaw > 0,
              ascLength > 0,
              offset + ascLength <= payload.count else {
            return
        }

        guard let aacFormat = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRateRaw),
            AVNumberOfChannelsKey: channelCountRaw
        ]),
        let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRateRaw),
            channels: AVAudioChannelCount(channelCountRaw),
            interleaved: false
        ),
        let decoder = AVAudioConverter(from: aacFormat, to: pcmFormat) else {
            return
        }
        self.aacFormat = aacFormat
        self.aacDecoder = decoder

        if audioEngine.isRunning {
            playerNode.stop()
            playerNode.reset()
            audioEngine.stop()
        }
        pendingBufferCount = 0
        hasStartedPlayback = false

        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcmFormat)

        if isStarted {
            do {
                try audioEngine.start()
            } catch {
                isStarted = false
            }
        }

        outputFormat = pcmFormat
    }

    private func enqueueFrameInternal(_ payload: Data) {
        guard isStarted,
              let outputFormat,
              let aacFormat,
              let aacDecoder,
              payload.count > 4 else {
            return
        }

        var offset = 0
        let byteCount = Int(payload.readUInt32(at: &offset))
        guard byteCount > 0, offset + byteCount <= payload.count else { return }
        let packet = payload.subdata(in: offset..<(offset + byteCount))

        let compressed = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(compressed.data, base, packet.count)
        }
        compressed.packetCount = 1
        compressed.byteLength = UInt32(packet.count)
        if let descriptions = compressed.packetDescriptions {
            descriptions[0].mStartOffset = 0
            descriptions[0].mVariableFramesInPacket = 0
            descriptions[0].mDataByteSize = UInt32(packet.count)
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2_048) else {
            return
        }
        nonisolated(unsafe) let feed = AACFeedOnce(buffer: compressed)
        var error: NSError?
        aacDecoder.convert(to: pcmBuffer, error: &error) { _, status in
            if feed.didFeed {
                status.pointee = .noDataNow
                return nil
            }
            feed.didFeed = true
            status.pointee = .haveData
            return compressed
        }
        guard error == nil, pcmBuffer.frameLength > 0 else { return }

        if pendingBufferCount >= maxPendingBuffers {
            // Favor continuity: drop newest frame instead of resetting playback.
            audioDebugDroppedFrameCount += 1
            if audioDebugDroppedFrameCount % 30 == 0 {
                print("[AudioDebug][ios-player] dropped=\(audioDebugDroppedFrameCount)")
            }
            return
        }

        pendingBufferCount += 1
        audioDebugScheduledFrameCount += 1
        if audioDebugScheduledFrameCount % 120 == 0 {
            print("[AudioDebug][ios-player] scheduled=\(audioDebugScheduledFrameCount) pending=\(pendingBufferCount)")
        }
        playerNode.scheduleBuffer(pcmBuffer) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.pendingBufferCount = max(0, self.pendingBufferCount - 1)
            }
        }

        if hasStartedPlayback == false,
           pendingBufferCount >= minPendingBuffersBeforePlay {
            playerNode.play()
            hasStartedPlayback = true
        }
    }
}

private final class AACFeedOnce: @unchecked Sendable {
    var didFeed = false
    let buffer: AVAudioCompressedBuffer

    init(buffer: AVAudioCompressedBuffer) {
        self.buffer = buffer
    }
}

private extension Data {
    func readUInt8(at offset: inout Int) -> UInt8 {
        guard offset < count else { return 0 }
        let value = self[offset]
        offset += 1
        return value
    }

    func readUInt16(at offset: inout Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        let value = (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
        offset += 2
        return value
    }

    func readUInt32(at offset: inout Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
