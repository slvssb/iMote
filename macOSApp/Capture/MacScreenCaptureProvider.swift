import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

actor MacScreenCaptureProvider {
    private var contentFilter: SCContentFilter?
    private var sourceWidth: CGFloat = 0
    private var sourceHeight: CGFloat = 0
    private var displayFrame: CGRect = .zero

    func makeFrameImage(maxWidth: CGFloat = 1920) async -> CGImage? {
        do {
            if contentFilter == nil {
                try await prepareCaptureFilter()
            }

            guard let filter = contentFilter,
                  sourceWidth > 0,
                  sourceHeight > 0 else {
                return nil
            }

            let scale = min(1.0, maxWidth / sourceWidth)
            let config = SCStreamConfiguration()
            config.width = Int(sourceWidth * scale)
            config.height = Int(sourceHeight * scale)

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }

    func normalizedCursorPosition() -> CGPoint? {
        guard displayFrame.isEmpty == false else { return nil }

        let location = NSEvent.mouseLocation
        let relativeX = (location.x - displayFrame.minX) / displayFrame.width
        let relativeY = (location.y - displayFrame.minY) / displayFrame.height

        let clampedX = min(max(relativeX, 0), 1)
        let clampedY = min(max(1 - relativeY, 0), 1)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func prepareCaptureFilter() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            return
        }

        sourceWidth = CGFloat(display.width)
        sourceHeight = CGFloat(display.height)
        displayFrame = display.frame
        contentFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }
}
