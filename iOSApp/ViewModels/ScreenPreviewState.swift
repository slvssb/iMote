import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ScreenPreviewState: ObservableObject {
    @Published var frameImage: UIImage?
    @Published var statsLabel = "No frames yet"
    @Published private(set) var followAnchor = UnitPoint.center

    let zoomScale: CGFloat = 2.2

    private var frameTimestamps: [Date] = []
    private var timerCancellable: AnyCancellable?

    init() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatsLabel()
            }
    }

    func reset() {
        frameImage = nil
        frameTimestamps.removeAll()
        statsLabel = "No frames yet"
        followAnchor = .center
    }

    func consumeFrameData(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        consumeFrameImage(image)
    }

    func consumeFrameImage(_ image: UIImage) {
        frameImage = image
        recordArrival()
    }

    func updateCursorPosition(x: Double, y: Double) {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)

        let alpha = 0.22
        let nextX = followAnchor.x + (clampedX - followAnchor.x) * alpha
        let nextY = followAnchor.y + (clampedY - followAnchor.y) * alpha
        followAnchor = UnitPoint(x: nextX, y: nextY)
    }

    private func recordArrival() {
        let now = Date()
        frameTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-5)
        frameTimestamps.removeAll { $0 < cutoff }
        updateStatsLabel()
    }

    private func updateStatsLabel() {
        guard let last = frameTimestamps.last else {
            statsLabel = "No frames yet"
            return
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-5)
        frameTimestamps.removeAll { $0 < cutoff }

        let fps = frameTimestamps.filter { $0 >= now.addingTimeInterval(-1) }.count
        let ageMs = Int(now.timeIntervalSince(last) * 1000)
        statsLabel = "~\(fps) fps • last frame \(ageMs) ms ago"
    }
}
