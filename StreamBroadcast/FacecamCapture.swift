import AVFoundation
import CoreVideo
import StreamCore

/// Runs a low-resolution front/back `AVCaptureSession` (per `StreamSettings`)
/// and stores ONLY the latest camera `CVPixelBuffer` into a `LatestCameraFrame`.
///
/// The entire camera body is guarded by `#if targetEnvironment(simulator)` so
/// the type still compiles and no-ops cleanly on the Simulator (no camera HW),
/// while doing real capture on device.
final class FacecamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                            @unchecked Sendable {

    /// Thread-safe holder for the most recent camera frame.
    let latest = LatestCameraFrame()

    #if targetEnvironment(simulator)

    // MARK: Simulator no-op implementation

    func start(with settings: StreamSettings) {
        // No camera hardware on the Simulator; intentionally does nothing.
    }

    func stop() {
        latest.clear()
    }

    #else

    // MARK: Device implementation

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.joeblau.Stream.Broadcast.facecam")
    private let output = AVCaptureVideoDataOutput()
    private var isConfigured = false

    func start(with settings: StreamSettings) {
        queue.async { [weak self] in
            self?.configureAndRun(with: settings)
        }
    }

    private func configureAndRun(with settings: StreamSettings) {
        guard !isConfigured else {
            if !session.isRunning { session.startRunning() }
            return
        }

        // The host app must have already granted camera permission — a broadcast
        // extension cannot present the permission prompt itself. Bail cleanly if
        // not authorized (the stream continues screen-only).
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.start(with: settings) }
            }
            return
        }
        guard authorization == .authorized else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        // Required for the camera to continue after the app backgrounds: without
        // multitasking camera access the session is interrupted with
        // .videoDeviceNotAvailableWithMultipleForegroundApps and delivers no frames.
        // Stream's signed target carries Apple's multitasking-camera entitlement;
        // keep the runtime guard so an incorrectly provisioned build still degrades
        // safely to screen-only instead of attempting an unsupported property set.
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }

        let position: AVCaptureDevice.Position =
            settings.cameraPosition == .front ? .front : .back

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)

            // AVCaptureVideoDataOutput otherwise delivers buffers in the camera
            // sensor's native landscape orientation. Ask AVFoundation for the
            // camera-specific angle (front/back sensors can differ) and have the
            // output physically rotate each buffer before it reaches Core Image.
            // Configure this before startRunning(): changing it live rebuilds the
            // capture render pipeline and can stall an active broadcast.
            let rotation = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: nil
            ).videoRotationAngleForHorizonLevelCapture
            if let connection = output.connection(with: .video),
               connection.isVideoRotationAngleSupported(rotation) {
                connection.videoRotationAngle = rotation
            }
        }

        session.commitConfiguration()
        isConfigured = true
        session.startRunning()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.latest.clear()
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest.store(pixelBuffer)
    }

    #endif
}
