import SwiftUI
import UIKit

struct TrackpadSurfaceView: UIViewRepresentable {
    var mouseScale: Double
    var scrollScale: Double
    var isNaturalScrollingEnabled: Bool
    var onMove: (Double, Double) -> Void
    var onScroll: (Double, Double) -> Void
    var onClick: (MouseButton, KeyAction) -> Void

    func makeUIView(context: Context) -> TrackpadGestureView {
        let view = TrackpadGestureView()
        view.onMove = onMove
        view.onScroll = onScroll
        view.onClick = onClick
        view.mouseScale = mouseScale
        view.scrollScale = scrollScale
        return view
    }

    func updateUIView(_ uiView: TrackpadGestureView, context: Context) {
        uiView.onMove = onMove
        uiView.onScroll = onScroll
        uiView.onClick = onClick
        uiView.mouseScale = mouseScale
        uiView.scrollScale = scrollScale
        uiView.isNaturalScrollingEnabled = isNaturalScrollingEnabled
        uiView.refreshTheme()
    }
}

final class TrackpadGestureView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onClick: ((MouseButton, KeyAction) -> Void)?
    var mouseScale: Double = 1.45
    var scrollScale: Double = 1.2
    var isNaturalScrollingEnabled = true

    private var isThreeFingerDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGestures()
    }

    private func configureGestures() {
        isMultipleTouchEnabled = true
        layer.cornerRadius = 12
        layer.borderWidth = 0.8
        clipsToBounds = true
        refreshTheme()

        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.delegate = self

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self

        let threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.delegate = self

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.delegate = self

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.delegate = self

        singleTap.require(toFail: oneFingerPan)
        twoFingerTap.require(toFail: twoFingerPan)
        threeFingerTap.require(toFail: threeFingerPan)

        addGestureRecognizer(oneFingerPan)
        addGestureRecognizer(twoFingerPan)
        addGestureRecognizer(threeFingerPan)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(twoFingerTap)
        addGestureRecognizer(threeFingerTap)
    }

    @objc private func handleOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)

        let deltaX = Double(translation.x) * mouseScale
        let deltaY = Double(translation.y) * mouseScale

        if deltaX != 0 || deltaY != 0 {
            onMove?(deltaX, deltaY)
        }
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)

        let deltaX = Double(translation.x) * scrollScale
        let rawDeltaY = Double(translation.y) * scrollScale
        let deltaY = isNaturalScrollingEnabled ? -rawDeltaY : rawDeltaY

        if deltaX != 0 || deltaY != 0 {
            onScroll?(deltaX, deltaY)
        }
    }

    @objc private func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isThreeFingerDragging = true
            onClick?(.left, .down)
        case .changed:
            let translation = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)

            let deltaX = Double(translation.x) * mouseScale
            let deltaY = Double(translation.y) * mouseScale
            if deltaX != 0 || deltaY != 0 {
                onMove?(deltaX, deltaY)
            }
        case .ended, .cancelled, .failed:
            if isThreeFingerDragging {
                onClick?(.left, .up)
                isThreeFingerDragging = false
            }
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            onClick?(.left, .tap)
        }
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            onClick?(.right, .tap)
        }
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            onClick?(.center, .tap)
        }
    }

    func refreshTheme() {
        if traitCollection.userInterfaceStyle == .dark {
            backgroundColor = UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1)
            layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        } else {
            backgroundColor = UIColor(red: 0.73, green: 0.74, blue: 0.76, alpha: 1)
            layer.borderColor = UIColor.white.withAlphaComponent(0.30).cgColor
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
