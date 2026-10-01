import AVFoundation
import CoreVideo
import StreamCore

/// Runs a low-resolution front/back `AVCaptureSession` (per `StreamSettings`)
/// and stores ONLY the latest camera `CVPixelBuffer` into a `LatestCameraFrame`.
///
/// The entire camera body is guarded by `#if targetEnvironment(simulator)` so
/// the type still compiles and no-ops cleanly on the Simulator (no camera HW),
/// while doing real capture on device.
///
/// On macOS there is no front/back camera pair: capture always uses
/// `AVCaptureDevice.default(for: .video)` (the built-in or continuity camera)
/// and the position is treated as `.front` so the facecam stays mirrored.
final class FacecamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                            @unchecked Sendable {

    /// Thread-safe holder for the most recent camera frame.
    let latest = LatestCameraFrame()

    #if targetEnvironment(simulator)

    // MARK: Simulator no-op implementation

    func start(with settings: StreamSettings, deviceUniqueID: String? = nil) {
        // No camera hardware on the Simulator; intentionally does nothing.
    }

    func setCameraPosition(_ position: CameraPosition) {
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
    /// The camera currently wired into the session. Mutated and read only on
    /// `queue`, which is also the sample-delivery queue — so the position stamped
    /// onto each stored frame is always the one that actually produced it.
    private var currentPosition: CameraPosition = .front
    /// The input for `currentPosition`, retained so a flip can swap it out without
    /// tearing the whole session down.
    private var videoInput: AVCaptureDeviceInput?
    /// Inputs kept per camera once built. `AVCaptureDevice.default` is a device
    /// discovery call and `AVCaptureDeviceInput.init` opens the device — both run on
    /// `queue`, which is also the sample-delivery queue, so repeating them on every
    /// flip stalls the preview for as long as they take. Removing an input from a
    /// session does not invalidate it, so flipping back reuses the one already built.
    private var inputsByPosition: [CameraPosition: AVCaptureDeviceInput] = [:]
    /// Whether the session is *meant* to be running. Recovery from an interruption
    /// or a media-services reset restarts capture only while this is true, so a
    /// notification arriving after `stop()` cannot resurrect the camera.
    private var isRunningDesired = false
    /// macOS only (S05, issue #73): the registry source's pinned capture-device
    /// unique ID; nil = system default camera. Read only on `queue`; set by
    /// `start` before `configureAndRun` so the permission-prompt retry and the
    /// media-services-reset rebuild keep resolving the same device.
    private var requestedDeviceUniqueID: String?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionRuntimeError),
                           name: AVCaptureSession.runtimeErrorNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded),
                           name: AVCaptureSession.interruptionEndedNotification, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Starts capture. `deviceUniqueID` (macOS) pins a specific camera from a
    /// registry source definition; nil keeps the system default. iOS ignores
    /// it (front/back selection stays on `settings.cameraPosition`).
    func start(with settings: StreamSettings, deviceUniqueID: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedDeviceUniqueID = deviceUniqueID
            self.configureAndRun(with: settings)
        }
    }

    /// Switches the live session between the front and back camera without
    /// stopping it. Reconfiguring in place (rather than rebuilding the session)
    /// keeps the swap around a couple of hundred milliseconds, and the previously
    /// stored frame stays on screen underneath until the new camera delivers.
    func setCameraPosition(_ position: CameraPosition) {
        queue.async { [weak self] in
            self?.applyPosition(position)
        }
    }

    private func configureAndRun(with settings: StreamSettings) {
        isRunningDesired = true
        guard !isConfigured else {
            applyPosition(settings.cameraPosition)
            if !session.isRunning { session.startRunning() }
            return
        }

        // The host app must have already granted camera permission — a broadcast
        // extension cannot present the permission prompt itself. Bail cleanly if
        // not authorized (the stream continues screen-only).
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if authorization == .notDetermined {
            let deviceUniqueID = requestedDeviceUniqueID
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.start(with: settings, deviceUniqueID: deviceUniqueID) }
            }
            return
        }
        guard authorization == .authorized else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        #if os(iOS)
        // Required for the camera to continue after the app backgrounds: without
        // multitasking camera access the session is interrupted with
        // .videoDeviceNotAvailableWithMultipleForegroundApps and delivers no frames.
        // Stream's signed target carries Apple's multitasking-camera entitlement;
        // keep the runtime guard so an incorrectly provisioned build still degrades
        // safely to screen-only instead of attempting an unsupported property set.
        // (iOS-only: macOS AVCaptureSession has no multitasking-camera concept.)
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        #endif

        guard let input = input(for: settings.cameraPosition),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoInput = input
        currentPosition = Self.effectivePosition(settings.cameraPosition)
        let device = input.device

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            applyRotation(for: device)
        }

        session.commitConfiguration()
        isConfigured = true
        session.startRunning()
    }

    /// Swaps the session's video input to `position`. No-op when the session isn't
    /// configured yet (the initial configuration reads the setting directly) or the
    /// requested camera is already live.
    private func applyPosition(_ position: CameraPosition) {
        let position = Self.effectivePosition(position)
        guard isConfigured else {
            currentPosition = position
            return
        }
        guard position != currentPosition else { return }
        guard let input = input(for: position) else { return }

        let previous = videoInput
        session.beginConfiguration()
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(input) else {
            // Leave the session on the camera it already had rather than inputless.
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoInput = input
        currentPosition = position
        // Front and back sensors can sit at different angles, so the physical
        // rotation the output applies has to be recomputed for the new device.
        applyRotation(for: input.device)
        session.commitConfiguration()
    }

    /// The input for `position`, built once and reused. Called only on `queue`.
    private func input(for position: CameraPosition) -> AVCaptureDeviceInput? {
        if let cached = inputsByPosition[position] { return cached }
        guard let device = device(for: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        inputsByPosition[position] = input
        return input
    }

    /// AVCaptureVideoDataOutput otherwise delivers buffers in the camera sensor's
    /// native landscape orientation. Ask AVFoundation for the camera-specific angle
    /// (front/back sensors can differ) and have the output physically rotate each
    /// buffer before it reaches Core Image. Always called inside a
    /// begin/commitConfiguration pair: changing it on a running pipeline outside one
    /// rebuilds the capture render pipeline and can stall an active broadcast.
    private func applyRotation(for device: AVCaptureDevice) {
        let rotation = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: nil
        ).videoRotationAngleForHorizonLevelCapture
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(rotation) {
            connection.videoRotationAngle = rotation
        }
    }

    /// The position a stored frame is stamped with. macOS has a single camera
    /// source (see `device(for:)`), which is always mirrored like a front camera.
    private static func effectivePosition(_ position: CameraPosition) -> CameraPosition {
        #if os(iOS)
        return position
        #else
        return .front
        #endif
    }

    private func device(for position: CameraPosition) -> AVCaptureDevice? {
        #if os(iOS)
        return AVCaptureDevice.default(.builtInWideAngleCamera,
                                       for: .video,
                                       position: position == .front ? .front : .back)
        #else
        // macOS has no front/back pair. A registry source can pin a specific
        // camera by unique ID (S05); otherwise capture uses the system default
        // video device (the built-in FaceTime camera, or a continuity/USB
        // camera the user chose in Control Center). Either way the device is
        // treated as `.front` so the PiP stays mirrored.
        if let uniqueID = requestedDeviceUniqueID,
           let device = AVCaptureDevice(uniqueID: uniqueID) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
        #endif
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunningDesired = false
            if self.session.isRunning {
                self.session.stopRunning()
            }
            // Keep only the input the session still holds. Caching the other camera
            // is what makes a flip back instant, but there is no reason to hold a
            // camera open once the facecam is off or the app has left the foreground.
            self.inputsByPosition = self.inputsByPosition.filter { $0.value === self.videoInput }
            self.latest.clear()
        }
    }

    // MARK: Recovery

    /// `AVCaptureSessionRuntimeError` ends capture silently — the facecam simply
    /// stops updating mid-broadcast with nothing in the UI to explain it. The common
    /// cause on this app's workload is a media-services reset (audio route churn
    /// while ScreenCaptureKit, the mic, and the camera all share the media server),
    /// which invalidates every session object and requires a full rebuild. The
    /// media-services reset code is iOS-only; macOS restarts the stopped session.
    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        queue.async { [weak self] in
            guard let self, self.isRunningDesired else { return }
            #if os(iOS)
            if error?.code == .mediaServicesWereReset {
                self.rebuildAfterMediaServicesReset()
                return
            }
            #endif
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    /// An interruption (a phone call, another app taking the camera) suspends the
    /// session; iOS does not resume it for us.
    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        queue.async { [weak self] in
            guard let self, self.isRunningDesired, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// Rebuilds the input/output graph on the existing session after a media
    /// services reset, then restarts it. The stored frame is dropped so the
    /// preview does not sit on a stale image while the camera comes back.
    private func rebuildAfterMediaServicesReset() {
        let position = currentPosition
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        videoInput = nil
        // A media services reset invalidates every capture object, cached inputs
        // included — they have to be rebuilt against the restarted server.
        inputsByPosition.removeAll()
        isConfigured = false
        latest.clear()
        var settings = StreamSettings.default
        settings.cameraPosition = position
        configureAndRun(with: settings)
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Delivered on `queue`, the same queue that owns `currentPosition`, so the
        // stamp is always the camera that produced these pixels.
        latest.store(pixelBuffer, position: currentPosition)
    }

    #endif
}
