import AVFoundation
import Foundation
import Vision

final class EyeCursorController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false

    var onMove: ((Double, Double) -> Void)?

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "imote.eye.capture", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "imote.eye.analysis", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var isConfigured = false
    private var isAnalyzingFrame = false
    private var frameCounter = 0
    private var debugNoFaceCounter = 0
    private var debugNoGazeCounter = 0
    private var debugMoveCounter = 0
    private var baselinePoint: CGPoint?
    private var smoothedOffset = CGPoint.zero
    private var lastMoveDispatchTime: CFTimeInterval = 0

    func start() {
        guard isRunning == false else { return }
        print("[EyeCursor] start() called")

        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("[EyeCursor] camera authorization status: \(authStatus.rawValue)")

        switch authStatus {
        case .authorized:
            print("[EyeCursor] authorization already granted")
            startCaptureSession()
        case .notDetermined:
            print("[EyeCursor] requesting camera permission")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("[EyeCursor] camera permission result: granted=\(granted)")
                guard granted else { return }
                self?.startCaptureSession()
            }
        case .denied, .restricted:
            print("[EyeCursor] camera access unavailable (denied/restricted)")
            break
        @unknown default:
            print("[EyeCursor] unknown camera authorization status")
            break
        }
    }

    func stop() {
        guard isRunning else { return }
        print("[EyeCursor] stop() called")

        captureQueue.async { [weak self] in
            guard let self else { return }
            print("[EyeCursor] stopping capture session")
            self.captureSession.stopRunning()
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
                print("[EyeCursor] isRunning=false")
            }
        }

        baselinePoint = nil
        smoothedOffset = .zero
    }

    private func startCaptureSession() {
        print("[EyeCursor] startCaptureSession()")
        configureIfNeeded()

        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.captureSession.isRunning == false else { return }
            print("[EyeCursor] starting AVCaptureSession.run()")
            self.captureSession.startRunning()
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = true
                print("[EyeCursor] isRunning=true")
            }
        }
    }

    private func configureIfNeeded() {
        guard isConfigured == false else { return }
        print("[EyeCursor] configureIfNeeded() - begin")

        captureQueue.sync {
            captureSession.beginConfiguration()
            captureSession.sessionPreset = .vga640x480

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                let input = try? AVCaptureDeviceInput(device: device),
                captureSession.canAddInput(input)
            else {
                print("[EyeCursor] configuration failed: missing front camera input")
                captureSession.commitConfiguration()
                return
            }
            captureSession.addInput(input)
            print("[EyeCursor] camera input added")

            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)

            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
                print("[EyeCursor] video output added")
            } else {
                print("[EyeCursor] configuration warning: cannot add video output")
            }

            if let connection = videoOutput.connection(with: .video) {
                connection.isVideoMirrored = true
                print("[EyeCursor] video connection mirrored")
            }

            captureSession.commitConfiguration()
            isConfigured = true
            print("[EyeCursor] configureIfNeeded() - complete")
        }
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        frameCounter += 1
        if frameCounter % 180 == 0 {
            print("[EyeCursor] frame heartbeat: frame=\(frameCounter) analyzing=\(isAnalyzingFrame)")
        }
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
                if (request.results as? [VNFaceObservation])?.isEmpty ?? true {
                    self.debugNoFaceCounter += 1
                    if self.debugNoFaceCounter % 30 == 0 {
                        print("[EyeCursor] no face detected (\(self.debugNoFaceCounter) times)")
                    }
                } else {
                    self.debugNoGazeCounter += 1
                    if self.debugNoGazeCounter % 20 == 0 {
                        print("[EyeCursor] face detected but gaze landmarks unavailable (\(self.debugNoGazeCounter) times)")
                    }
                }
                return
            }

            self.process(gazePoint: gazePoint)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        do {
            try handler.perform([request])
        } catch {
            isAnalyzingFrame = false
            print("[EyeCursor] Vision request failed: \(error.localizedDescription)")
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

    private func process(gazePoint: CGPoint) {
        if baselinePoint == nil {
            baselinePoint = gazePoint
            print("[EyeCursor] baseline initialized at x=\(gazePoint.x), y=\(gazePoint.y)")
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

        debugMoveCounter += 1
        if debugMoveCounter % 12 == 0 {
            print("[EyeCursor] onMove deltaX=\(deltaX), deltaY=\(deltaY)")
        }
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
