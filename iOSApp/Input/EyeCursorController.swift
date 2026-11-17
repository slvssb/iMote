import AVFoundation
import Foundation
import Vision

final class EyeCursorController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false

    var onMove: ((Double, Double) -> Void)?

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "imote.eye.capture", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "imote.eye.analysis", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "imote.eye.state")
    private let videoOutput = AVCaptureVideoDataOutput()

    private var isConfigured = false
    private var isAnalyzingFrame = false
    private var frameCounter = 0
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64 = 0
    private var baselinePoint: CGPoint?
    private var smoothedOffset = CGPoint.zero
    private var lastMoveDispatchTime: CFTimeInterval = 0

    func start() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch authStatus {
        case .authorized:
            beginStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.beginStart()
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.activeGeneration = 0
            self.baselinePoint = nil
            self.smoothedOffset = .zero
            self.lastMoveDispatchTime = 0
        }

        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
        }
    }

    private func beginStart() {
        let token: UInt64 = stateQueue.sync {
            nextGeneration &+= 1
            activeGeneration = nextGeneration
            return activeGeneration
        }
        configureIfNeeded()

        captureQueue.async { [weak self] in
            guard let self else { return }
            let stillCurrent = self.stateQueue.sync { self.activeGeneration == token }
            guard stillCurrent else { return }
            if self.captureSession.isRunning == false {
                self.captureSession.startRunning()
            }
            let remainsCurrent = self.stateQueue.sync { self.activeGeneration == token }
            if remainsCurrent == false {
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.isRunning = false
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = true
            }
        }
    }

    private func configureIfNeeded() {
        guard isConfigured == false else { return }

        captureQueue.sync {
            captureSession.beginConfiguration()
            captureSession.sessionPreset = .vga640x480

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                let input = try? AVCaptureDeviceInput(device: device),
                captureSession.canAddInput(input)
            else {
                captureSession.commitConfiguration()
                return
            }
            captureSession.addInput(input)

            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)

            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }

            if let connection = videoOutput.connection(with: .video) {
                connection.isVideoMirrored = true
            }

            captureSession.commitConfiguration()
            isConfigured = true
        }
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        let token = stateQueue.sync { activeGeneration }
        guard token != 0 else { return }
        frameCounter += 1
        guard frameCounter % 3 == 0 else { return }
        guard isAnalyzingFrame == false else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isAnalyzingFrame = true

        let request = VNDetectFaceLandmarksRequest { [weak self] request, _ in
            guard let self else { return }
            defer { self.isAnalyzingFrame = false }

            guard let observation = (request.results as? [VNFaceObservation])?.first,
                  let gazePoint = self.estimatedGazePoint(from: observation)
            else {
                return
            }

            self.process(gazePoint: gazePoint, generation: token)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        do {
            try handler.perform([request])
        } catch {
            isAnalyzingFrame = false
        }
    }

    private func estimatedGazePoint(from observation: VNFaceObservation) -> CGPoint? {
        guard let landmarks = observation.landmarks else { return nil }

        let leftEye = centerPoint(of: landmarks.leftPupil ?? landmarks.leftEye)
        let rightEye = centerPoint(of: landmarks.rightPupil ?? landmarks.rightEye)

        let facePoint: CGPoint
        if let leftEye, let rightEye {
            facePoint = CGPoint(x: (leftEye.x + rightEye.x) * 0.5, y: (leftEye.y + rightEye.y) * 0.5)
        } else if let leftEye {
            facePoint = leftEye
        } else if let rightEye {
            facePoint = rightEye
        } else {
            return nil
        }

        let box = observation.boundingBox
        return CGPoint(
            x: box.origin.x + (facePoint.x * box.width),
            y: box.origin.y + (facePoint.y * box.height)
        )
    }

    private func centerPoint(of region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let region else { return nil }
        let points = region.normalizedPoints
        guard points.isEmpty == false else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in points {
            sumX += point.x
            sumY += point.y
        }

        return CGPoint(
            x: sumX / CGFloat(points.count),
            y: sumY / CGFloat(points.count)
        )
    }

    private func process(gazePoint: CGPoint, generation: UInt64) {
        stateQueue.async { [weak self] in
            self?.processOnStateQueue(gazePoint: gazePoint, generation: generation)
        }
    }

    private func processOnStateQueue(gazePoint: CGPoint, generation: UInt64) {
        guard activeGeneration == generation else { return }
        if baselinePoint == nil {
            baselinePoint = gazePoint
            return
        }

        guard let baseline = baselinePoint else { return }

        // Adapt baseline slowly to reduce drift from posture changes.
        let baselineAdaptAlpha: CGFloat = 0.015
        baselinePoint = CGPoint(
            x: baseline.x + (gazePoint.x - baseline.x) * baselineAdaptAlpha,
            y: baseline.y + (gazePoint.y - baseline.y) * baselineAdaptAlpha
        )

        let rawOffset = CGPoint(x: gazePoint.x - baseline.x, y: gazePoint.y - baseline.y)

        // Smooth the control signal for steady cursor movement.
        let smoothingAlpha: CGFloat = 0.22
        smoothedOffset = CGPoint(
            x: smoothedOffset.x + (rawOffset.x - smoothedOffset.x) * smoothingAlpha,
            y: smoothedOffset.y + (rawOffset.y - smoothedOffset.y) * smoothingAlpha
        )

        let deadZone: CGFloat = 0.010
        let filteredX = abs(smoothedOffset.x) > deadZone ? smoothedOffset.x : 0
        let filteredY = abs(smoothedOffset.y) > deadZone ? smoothedOffset.y : 0

        let sensitivity: Double = 760
        let deltaX = Double(filteredX) * sensitivity
        let deltaY = -Double(filteredY) * sensitivity

        if abs(deltaX) + abs(deltaY) < 0.6 {
            return
        }

        // Limit outbound cursor updates to smooth jittery bursts.
        let now = CACurrentMediaTime()
        let minDispatchInterval: CFTimeInterval = 1.0 / 55.0
        guard (now - lastMoveDispatchTime) >= minDispatchInterval else { return }
        lastMoveDispatchTime = now

        DispatchQueue.main.async { [weak self] in
            self?.onMove?(deltaX, deltaY)
        }
    }
}

extension EyeCursorController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        self.handle(sampleBuffer: sampleBuffer)
    }
}
