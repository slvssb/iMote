@preconcurrency import AVFoundation
import Foundation

final class AACAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "remote.keyboard.pcm.player")
    private let minPendingBuffersBeforePlay = 4
    private let maxPendingBuffers = 16

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var outputFormat: AVAudioFormat?
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
        guard payload.count >= 5 else { return }

        var offset = 0
        let sampleRateRaw = payload.readUInt32(at: &offset)
        let channelCountRaw = payload.readUInt8(at: &offset)

        guard sampleRateRaw > 0,
              channelCountRaw > 0,
              let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRateRaw),
                channels: AVAudioChannelCount(channelCountRaw),
                interleaved: false
              ) else {
            return
        }

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
              payload.count >= 6 else {
            return
        }

        var offset = 0
        let frameCount = Int(payload.readUInt32(at: &offset))
        let channelCount = Int(payload.readUInt8(at: &offset))

        guard frameCount > 0,
              channelCount == Int(outputFormat.channelCount),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = pcmBuffer.floatChannelData else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        for channel in 0..<channelCount {
            let byteCount = Int(payload.readUInt32(at: &offset))
            guard byteCount == frameCount * MemoryLayout<Float>.size,
                  offset + byteCount <= payload.count else {
                return
            }

            payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                let src = base.advanced(by: offset)
                memcpy(channelData[channel], src, byteCount)
            }
            offset += byteCount
        }

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

private extension Data {
    func readUInt8(at offset: inout Int) -> UInt8 {
        guard offset < count else { return 0 }
        let value = self[offset]
        offset += 1
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
