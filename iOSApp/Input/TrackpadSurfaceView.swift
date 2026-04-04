import SwiftUI
import UIKit

struct TrackpadSurfaceView: UIViewRepresentable {
    enum SwipeDirection {
        case up
        case down
        case left
        case right
    }

    var mouseScale: Double
    var scrollScale: Double
    var isNaturalScrollingEnabled: Bool
    var onMove: (Double, Double) -> Void
    var onScroll: (Double, Double) -> Void
    var onClick: (MouseButton, KeyAction) -> Void
    var onFourFingerSwipe: (SwipeDirection) -> Void
    var isVisualChromeEnabled: Bool = true

    func makeUIView(context: Context) -> TrackpadGestureView {
        let view = TrackpadGestureView()
        view.onMove = onMove
        view.onScroll = onScroll
        view.onClick = onClick
        view.onFourFingerSwipe = onFourFingerSwipe
        view.mouseScale = mouseScale
        view.scrollScale = scrollScale
        view.isVisualChromeEnabled = isVisualChromeEnabled
        return view
    }

    func updateUIView(_ uiView: TrackpadGestureView, context: Context) {
        uiView.onMove = onMove
        uiView.onScroll = onScroll
        uiView.onClick = onClick
        uiView.onFourFingerSwipe = onFourFingerSwipe
        uiView.mouseScale = mouseScale
        uiView.scrollScale = scrollScale
        uiView.isNaturalScrollingEnabled = isNaturalScrollingEnabled
        uiView.isVisualChromeEnabled = isVisualChromeEnabled
        uiView.refreshTheme()
    }
}

final class TrackpadGestureView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onClick: ((MouseButton, KeyAction) -> Void)?
    var onFourFingerSwipe: ((TrackpadSurfaceView.SwipeDirection) -> Void)?
    var mouseScale: Double = 1.45
    var scrollScale: Double = 1.2
    var isNaturalScrollingEnabled = true
    var isVisualChromeEnabled = true

    private var isThreeFingerDragging = false
    private var isLeftLongPressActive = false
    private var isRightLongPressActive = false
    private let leftClickFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let rightClickFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let centerClickFeedback = UIImpactFeedbackGenerator(style: .rigid)
    private var touchVisuals: [ObjectIdentifier: TouchVisualState] = [:]
    private lazy var trailParticleImage: CGImage = makeTrailParticleImage()

    private struct TouchVisualState {
        var lastPoint: CGPoint
        let dotLayer: CAShapeLayer
        let emitterLayer: CAEmitterLayer
    }

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
        prepareHaptics()

        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.delegate = self
        oneFingerPan.cancelsTouchesInView = false

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        twoFingerPan.cancelsTouchesInView = false

        let threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.delegate = self
        threeFingerPan.cancelsTouchesInView = false

        let fourFingerSwipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleFourFingerSwipe(_:)))
        fourFingerSwipeUp.numberOfTouchesRequired = 4
        fourFingerSwipeUp.direction = .up
        fourFingerSwipeUp.delegate = self
        fourFingerSwipeUp.cancelsTouchesInView = false

        let fourFingerSwipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleFourFingerSwipe(_:)))
        fourFingerSwipeDown.numberOfTouchesRequired = 4
        fourFingerSwipeDown.direction = .down
        fourFingerSwipeDown.delegate = self
        fourFingerSwipeDown.cancelsTouchesInView = false

        let fourFingerSwipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleFourFingerSwipe(_:)))
        fourFingerSwipeLeft.numberOfTouchesRequired = 4
        fourFingerSwipeLeft.direction = .left
        fourFingerSwipeLeft.delegate = self
        fourFingerSwipeLeft.cancelsTouchesInView = false

        let fourFingerSwipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleFourFingerSwipe(_:)))
        fourFingerSwipeRight.numberOfTouchesRequired = 4
        fourFingerSwipeRight.direction = .right
        fourFingerSwipeRight.delegate = self
        fourFingerSwipeRight.cancelsTouchesInView = false

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        singleTap.cancelsTouchesInView = false

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        doubleTap.cancelsTouchesInView = false

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.delegate = self
        twoFingerTap.cancelsTouchesInView = false

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.delegate = self
        threeFingerTap.cancelsTouchesInView = false

        let oneFingerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleOneFingerLongPress(_:)))
        oneFingerLongPress.minimumPressDuration = 0.35
        oneFingerLongPress.allowableMovement = 24
        oneFingerLongPress.numberOfTouchesRequired = 1
        oneFingerLongPress.delegate = self
        oneFingerLongPress.cancelsTouchesInView = false

        let twoFingerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTwoFingerLongPress(_:)))
        twoFingerLongPress.minimumPressDuration = 0.35
        twoFingerLongPress.allowableMovement = 24
        twoFingerLongPress.numberOfTouchesRequired = 2
        twoFingerLongPress.delegate = self
        twoFingerLongPress.cancelsTouchesInView = false

        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: oneFingerLongPress)
        singleTap.require(toFail: oneFingerPan)
        doubleTap.require(toFail: oneFingerPan)
        doubleTap.require(toFail: oneFingerLongPress)
        twoFingerTap.require(toFail: twoFingerPan)
        twoFingerTap.require(toFail: twoFingerLongPress)
        threeFingerTap.require(toFail: threeFingerPan)

        addGestureRecognizer(oneFingerPan)
        addGestureRecognizer(twoFingerPan)
        addGestureRecognizer(threeFingerPan)
        addGestureRecognizer(fourFingerSwipeUp)
        addGestureRecognizer(fourFingerSwipeDown)
        addGestureRecognizer(fourFingerSwipeLeft)
        addGestureRecognizer(fourFingerSwipeRight)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(twoFingerTap)
        addGestureRecognizer(threeFingerTap)
        addGestureRecognizer(oneFingerLongPress)
        addGestureRecognizer(twoFingerLongPress)
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
            triggerClickHaptic(for: .left)
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
                triggerClickHaptic(for: .left)
                onClick?(.left, .up)
                isThreeFingerDragging = false
            }
        default:
            break
        }
    }

    @objc private func handleFourFingerSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let direction: TrackpadSurfaceView.SwipeDirection
        switch recognizer.direction {
        case .up:
            direction = .up
        case .down:
            direction = .down
        case .left:
            direction = .left
        case .right:
            direction = .right
        default:
            return
        }
        onFourFingerSwipe?(direction)
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            triggerClickHaptic(for: .left)
            onClick?(.left, .tap)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            triggerClickHaptic(for: .left)
            onClick?(.left, .tap)
            onClick?(.left, .tap)
        }
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            triggerClickHaptic(for: .right)
            onClick?(.right, .tap)
        }
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            triggerClickHaptic(for: .center)
            onClick?(.center, .tap)
        }
    }

    @objc private func handleOneFingerLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard isLeftLongPressActive == false else { return }
            isLeftLongPressActive = true
            triggerClickHaptic(for: .left)
            onClick?(.left, .down)
        case .ended, .cancelled, .failed:
            guard isLeftLongPressActive else { return }
            isLeftLongPressActive = false
            triggerClickHaptic(for: .left)
            onClick?(.left, .up)
        default:
            break
        }
    }

    @objc private func handleTwoFingerLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard isRightLongPressActive == false else { return }
            isRightLongPressActive = true
            triggerClickHaptic(for: .right)
            onClick?(.right, .down)
        case .ended, .cancelled, .failed:
            guard isRightLongPressActive else { return }
            isRightLongPressActive = false
            triggerClickHaptic(for: .right)
            onClick?(.right, .up)
        default:
            break
        }
    }

    private func prepareHaptics() {
        leftClickFeedback.prepare()
        rightClickFeedback.prepare()
        centerClickFeedback.prepare()
    }

    private func triggerClickHaptic(for button: MouseButton) {
        switch button {
        case .left:
            leftClickFeedback.impactOccurred(intensity: 0.55)
            leftClickFeedback.prepare()
        case .right:
            rightClickFeedback.impactOccurred(intensity: 0.75)
            rightClickFeedback.prepare()
        case .center:
            centerClickFeedback.impactOccurred(intensity: 0.9)
            centerClickFeedback.prepare()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            upsertTouchVisual(for: touch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        for touch in touches {
            upsertTouchVisual(for: touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        for touch in touches {
            removeTouchVisual(for: touch, animated: true)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        for touch in touches {
            removeTouchVisual(for: touch, animated: true)
        }
    }

    private func upsertTouchVisual(for touch: UITouch) {
        let key = ObjectIdentifier(touch)
        let point = touch.location(in: self)

        if var state = touchVisuals[key] {
            let distance = hypot(point.x - state.lastPoint.x, point.y - state.lastPoint.y)
            let movementFactor = min(max(distance / 14.0, 0), 1)
            let dynamicBirthRate = Float(0.12 + (movementFactor * 0.88))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            state.dotLayer.position = point
            state.emitterLayer.emitterPosition = point
            state.emitterLayer.birthRate = dynamicBirthRate
            CATransaction.commit()
            state.lastPoint = point
            touchVisuals[key] = state
            return
        }

        let dotLayer = CAShapeLayer()
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        dotLayer.position = point
        dotLayer.path = UIBezierPath(ovalIn: dotLayer.bounds).cgPath
        dotLayer.fillColor = UIColor.white.withAlphaComponent(0.85).cgColor
        dotLayer.shadowColor = UIColor.white.cgColor
        dotLayer.shadowRadius = 8
        dotLayer.shadowOpacity = 0.45
        dotLayer.shadowOffset = .zero
        dotLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull()
        ]

        let emitterCell = CAEmitterCell()
        emitterCell.contents = trailParticleImage
        emitterCell.birthRate = 68
        emitterCell.lifetime = 0.36
        emitterCell.lifetimeRange = 0.02
        emitterCell.velocity = 10
        emitterCell.velocityRange = 1.5
        emitterCell.scale = 0.18
        emitterCell.scaleRange = 0.03
        emitterCell.alphaSpeed = -2.2
        emitterCell.emissionRange = .pi * 2
        emitterCell.color = UIColor.white.withAlphaComponent(0.72).cgColor

        let emitterLayer = CAEmitterLayer()
        emitterLayer.emitterShape = .point
        emitterLayer.emitterMode = .points
        emitterLayer.renderMode = .oldestLast
        emitterLayer.emitterPosition = point
        emitterLayer.birthRate = 0.2
        emitterLayer.emitterCells = [emitterCell]
        emitterLayer.actions = [
            "emitterPosition": NSNull(),
            "opacity": NSNull()
        ]

        layer.addSublayer(emitterLayer)
        layer.addSublayer(dotLayer)

        touchVisuals[key] = TouchVisualState(
            lastPoint: point,
            dotLayer: dotLayer,
            emitterLayer: emitterLayer
        )
    }

    private func removeTouchVisual(for touch: UITouch, animated: Bool) {
        let key = ObjectIdentifier(touch)
        guard let state = touchVisuals.removeValue(forKey: key) else { return }

        if animated {
            state.emitterLayer.birthRate = 0
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                state.dotLayer.removeFromSuperlayer()
                state.emitterLayer.removeFromSuperlayer()
            }

            let dotFade = CABasicAnimation(keyPath: "opacity")
            dotFade.fromValue = 1
            dotFade.toValue = 0
            dotFade.duration = 0.18
            dotFade.timingFunction = CAMediaTimingFunction(name: .easeOut)

            // Let particles linger briefly, then fade out smoothly.
            let emitterFade = CABasicAnimation(keyPath: "opacity")
            emitterFade.fromValue = 1
            emitterFade.toValue = 0
            emitterFade.beginTime = CACurrentMediaTime() + 0.12
            emitterFade.duration = 0.42
            emitterFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            emitterFade.fillMode = .both
            emitterFade.isRemovedOnCompletion = false

            state.dotLayer.opacity = 0
            state.emitterLayer.opacity = 0
            state.dotLayer.add(dotFade, forKey: "touchFade")
            state.emitterLayer.add(emitterFade, forKey: "trailFade")
            CATransaction.commit()
        } else {
            state.dotLayer.removeFromSuperlayer()
            state.emitterLayer.removeFromSuperlayer()
        }
    }

    private func makeTrailParticleImage() -> CGImage {
        let size = CGSize(width: 24, height: 24)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.white.withAlphaComponent(0.95).cgColor,
                    UIColor.white.withAlphaComponent(0.55).cgColor,
                    UIColor.white.withAlphaComponent(0.0).cgColor
                ] as CFArray,
                locations: [0.0, 0.35, 1.0]
            )
            if let gradient {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: center,
                    startRadius: 0,
                    endCenter: center,
                    endRadius: size.width / 2,
                    options: []
                )
            } else {
                context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
                context.cgContext.fillEllipse(in: rect)
            }
        }
        guard let cgImage = image.cgImage else {
            fatalError("Failed to create trail particle image")
        }
        return cgImage
    }

    func refreshTheme() {
        if isVisualChromeEnabled == false {
            backgroundColor = .clear
            layer.borderColor = UIColor.clear.cgColor
            layer.borderWidth = 0
            return
        }

        layer.borderWidth = 0.8
        if traitCollection.userInterfaceStyle == .dark {
            backgroundColor = UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1)
            layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        } else {
            backgroundColor = UIColor(red: 0.73, green: 0.74, blue: 0.76, alpha: 1)
            layer.borderColor = UIColor.white.withAlphaComponent(0.30).cgColor
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let leftHoldWithOneFingerPan =
            (gestureRecognizer is UILongPressGestureRecognizer && (gestureRecognizer as? UILongPressGestureRecognizer)?.numberOfTouchesRequired == 1 && otherGestureRecognizer is UIPanGestureRecognizer && (otherGestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1) ||
            (otherGestureRecognizer is UILongPressGestureRecognizer && (otherGestureRecognizer as? UILongPressGestureRecognizer)?.numberOfTouchesRequired == 1 && gestureRecognizer is UIPanGestureRecognizer && (gestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1)
        return leftHoldWithOneFingerPan
    }
}
