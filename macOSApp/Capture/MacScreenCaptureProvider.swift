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
    private var activeDisplayID: CGDirectDisplayID?
    private var sourceWidth: CGFloat = 0
    private var sourceHeight: CGFloat = 0
    private var displayFrame: CGRect = .zero
    private var cgFrame: CGRect = .zero
    private var appKitFrame: CGRect = .zero
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private let outputQueue = DispatchQueue(label: "remote.keyboard.capture.output")
    private var latestPixelBuffer: CapturedPixelBuffer?
    private var activeMaxWidth: CGFloat = 0
    private var audioCaptureSource: AudioCaptureSource = .off
    private var audioSampleHandler: ((CapturedAudioSampleBuffer) -> Void)?
    private var activeCaptureRouteLabel: String = "Unknown"
    private var activeSummaryLabel: String = "No display"
    private var activeDisplayName: String = ""
    private var activeDisplayKind: String = ""
    private var virtualDisplayID: CGDirectDisplayID?
    private var preferredDisplayID: CGDirectDisplayID = 0
    private var preferredIdentity: DisplayHardwareIdentity?
    private var needsRetarget = false

    func makeFramePixelBuffer(maxWidth: CGFloat = 1920) async -> CapturedPixelBuffer? {
        do {
            if needsRetarget {
                needsRetarget = false
                contentFilter = nil
                await stopStreamOnly()
            }
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
        self.activeDisplayID = nil
        self.activeCaptureRouteLabel = "Unknown"
        self.activeSummaryLabel = "No display"
        self.activeDisplayName = ""
        self.activeDisplayKind = ""
        self.latestPixelBuffer = nil
        self.activeMaxWidth = 0
        self.cgFrame = .zero
        self.appKitFrame = .zero
        self.displayFrame = .zero
    }

    private func stopStreamOnly() async {
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
        self.activeMaxWidth = 0
        self.latestPixelBuffer = nil
    }

    func recoverAfterSystemWake(maxWidth: CGFloat = 1920) async -> Bool {
        needsRetarget = false
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

    func normalizedCursorPosition() async -> CGPoint? {
        guard appKitFrame.isEmpty == false, appKitFrame.width > 0, appKitFrame.height > 0 else { return nil }

        // NSEvent is AppKit space (origin at the bottom-left of the main display, y up).
        // The preview dot uses the top-left of the captured display, so y is flipped here.
        let frame = appKitFrame
        let location = await MainActor.run { NSEvent.mouseLocation }
        let relativeX = (location.x - frame.minX) / frame.width
        let relativeY = (location.y - frame.minY) / frame.height
        return CGPoint(
            x: min(max(relativeX, 0), 1),
            y: min(max(1 - relativeY, 0), 1)
        )
    }

    func currentCaptureRouteLabel() -> String {
        activeCaptureRouteLabel
    }

    func currentCaptureSnapshot() -> CaptureTargetSnapshot? {
        guard let activeDisplayID, sourceWidth > 0, sourceHeight > 0 else { return nil }
        let asleep = CGDisplayIsAsleep(activeDisplayID) != 0
        var label = activeSummaryLabel
        if asleep, label.contains("asleep") == false {
            label += " · asleep"
        }
        if asleep == false {
            label = label.replacingOccurrences(of: " · asleep", with: "")
        }
        return CaptureTargetSnapshot(
            displayID: activeDisplayID,
            name: activeDisplayName,
            kind: activeDisplayKind,
            width: Int(sourceWidth),
            height: Int(sourceHeight),
            cgBounds: cgFrame,
            summaryLabel: label,
            isVirtual: activeDisplayKind == HostDisplayKind.virtual.rawValue,
            isAsleep: asleep
        )
    }

    func setSelectionPolicy(
        virtualDisplayID: CGDirectDisplayID?,
        preferredDisplayID: CGDirectDisplayID,
        preferredIdentity: DisplayHardwareIdentity?
    ) {
        let changed = self.virtualDisplayID != virtualDisplayID
            || self.preferredDisplayID != preferredDisplayID
            || self.preferredIdentity != preferredIdentity
        self.virtualDisplayID = virtualDisplayID
        self.preferredDisplayID = preferredDisplayID
        self.preferredIdentity = preferredIdentity
        if changed {
            needsRetarget = true
        }
    }

    /// Older call sites used this to jump to a dummy plug while the main display slept.
    /// Selection now prefers an awake physical display, then the virtual display, so a
    /// caller only needs to force the next frame to look again.
    func setPreferFallbackDisplay(_ enabled: Bool) {
        _ = enabled
        needsRetarget = true
    }

    fileprivate func noteStreamStopped() {
        needsRetarget = true
    }

    private func prepareCaptureFilter() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = selectCaptureDisplay(from: content.displays) else {
            activeDisplayID = nil
            activeCaptureRouteLabel = "No display"
            activeSummaryLabel = "No display"
            activeDisplayName = ""
            activeDisplayKind = ""
            sourceWidth = 0
            sourceHeight = 0
            displayFrame = .zero
            cgFrame = .zero
            appKitFrame = .zero
            contentFilter = nil
            return
        }

        sourceWidth = CGFloat(display.width)
        sourceHeight = CGFloat(display.height)
        cgFrame = CGDisplayBounds(display.displayID)
        appKitFrame = Self.appKitBounds(fromCG: cgFrame)
        displayFrame = appKitFrame
        activeDisplayID = display.displayID
        let kind = Self.kind(for: display.displayID, virtualDisplayID: virtualDisplayID)
        activeDisplayKind = kind.rawValue
        let name = await Self.localizedName(for: display.displayID, kind: kind)
        activeDisplayName = name
        let asleep = CGDisplayIsAsleep(display.displayID) != 0
        activeSummaryLabel = Self.summaryLabel(name: name, width: display.width, height: display.height, isAsleep: asleep)
        activeCaptureRouteLabel = activeSummaryLabel
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
        let stream = SCStream(filter: filter, configuration: config, delegate: streamOutput)
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

    private func selectCaptureDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        let candidates = displays.map { display in
            CaptureDisplayCandidate(
                id: display.displayID,
                pixelCount: display.width * display.height,
                isAsleep: CGDisplayIsAsleep(display.displayID) != 0,
                isVirtual: Self.isVirtual(display.displayID, virtualDisplayID: virtualDisplayID),
                isMain: display.displayID == CGMainDisplayID()
            )
        }
        guard let chosen = CaptureDisplaySelection.choose(from: candidates, preferredID: resolvePreferredID(in: displays)),
              let display = displays.first(where: { $0.displayID == chosen.id }) else {
            return nil
        }
        return display
    }

    private func resolvePreferredID(in displays: [SCDisplay]) -> UInt32 {
        guard preferredDisplayID != 0 else { return 0 }
        if displays.contains(where: { $0.displayID == preferredDisplayID }) {
            return preferredDisplayID
        }
        guard let preferredIdentity, preferredIdentity.isSpecific else { return 0 }
        let matches = displays.filter { Self.hardwareIdentity(for: $0.displayID) == preferredIdentity }
        guard matches.count == 1, let match = matches.first else { return 0 }
        return match.displayID
    }

    private static func isVirtual(_ id: CGDirectDisplayID, virtualDisplayID: CGDirectDisplayID?) -> Bool {
        VirtualDisplayManager.isOurVirtualDisplay(id, knownID: virtualDisplayID)
    }

    private static func kind(for id: CGDirectDisplayID, virtualDisplayID: CGDirectDisplayID?) -> HostDisplayKind {
        if isVirtual(id, virtualDisplayID: virtualDisplayID) {
            return .virtual
        }
        if CGDisplayIsBuiltin(id) != 0 {
            return .builtin
        }
        return .physical
    }

    private static func hardwareIdentity(for id: CGDirectDisplayID) -> DisplayHardwareIdentity {
        DisplayHardwareIdentity(
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id)
        )
    }

    /// Quartz bounds put the origin at the top-left of the main display.
    /// AppKit puts it at the bottom-left, with the same point size.
    private static func appKitBounds(fromCG cgFrame: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: cgFrame.origin.x,
            y: primaryHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    private static func summaryLabel(name: String, width: Int, height: Int, isAsleep: Bool) -> String {
        let base = "\(name) · \(width)×\(height)"
        return isAsleep ? "\(base) · asleep" : base
    }

    @MainActor
    private static func localizedName(for displayID: CGDirectDisplayID, kind: HostDisplayKind) -> String {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber else {
                continue
            }
            guard number.uint32Value == displayID else { continue }
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty == false {
                return kind == .virtual ? "Virtual display" : name
            }
        }
        switch kind {
        case .virtual:
            return "Virtual display"
        case .builtin:
            return "Built-in display"
        case .physical:
            return "Display"
        }
    }
}

struct CaptureTargetSnapshot: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var name: String
    var kind: String
    var width: Int
    var height: Int
    var cgBounds: CGRect
    var summaryLabel: String
    var isVirtual: Bool
    var isAsleep: Bool
}
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
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

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let owner else { return }
        Task {
            await owner.noteStreamStopped()
        }
    }
}
