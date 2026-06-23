import ReplayKit
import AVFoundation
import CoreMedia
import VideoToolbox
import StreamCore

/// Principal class of the broadcast upload extension. Loads settings from the
/// App Group, configures the audio session (incl. the persisted Bluetooth mic),
/// optionally starts the facecam, and routes ReplayKit buffers into the
/// `RTMPPublisher` actor.
///
/// `@unchecked Sendable`: the class itself holds only immutable/actor-isolated
/// or lock-guarded collaborators; per buffer it spawns `Task { await ... }`.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    private let publisher = RTMPPublisher()
    private let facecam = FacecamCapture()
    private let compositor = FacecamCompositor()
    private let settings: StreamSettings

    /// Encode dimensions, locked once from the first screen frame so the stream
    /// matches the device's real orientation/aspect. Touched only on the serial
    /// ReplayKit sample-delivery thread.
    private var targetSize: CGSize = .zero
    private var sizeLocked = false

    override init() {
        self.settings = SettingsStore().load()
        super.init()
    }

    // MARK: - Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // Configure + activate the audio session and re-apply the BT mic UID.
        do {
            try AudioSessionConfigurator.configure(with: settings)
        } catch {
            // Audio routing failed; continue with video so the broadcast still
            // starts. The user simply may not get the preferred mic route.
        }

        // Start the facecam only when PIP is enabled (and only on device).
        if settings.pipEnabled {
            facecam.start(with: settings)
        }

        let settings = self.settings
        let publisher = self.publisher
        Task {
            do {
                try await publisher.start(settings)
            } catch {
                // Surface a clean failure to the system UI if publish fails.
                self.finishBroadcastWithError(error)
            }
        }
    }

    override func broadcastPaused() {
        // ReplayKit will stop delivering samples; nothing to tear down here.
    }

    override func broadcastResumed() {
        // Sample delivery resumes; the pipeline remains live.
    }

    override func broadcastFinished() {
        facecam.stop()
        let publisher = self.publisher
        Task {
            await publisher.stop()
        }
    }

    // MARK: - Sample routing

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            handleVideo(sampleBuffer)

        case .audioMic:
            if sampleBuffer.dataReadiness == .ready {
                let publisher = self.publisher
                Task { await publisher.appendMic(sampleBuffer) }
            }

        case .audioApp:
            if settings.includeAppAudio, sampleBuffer.dataReadiness == .ready {
                let publisher = self.publisher
                Task { await publisher.appendApp(sampleBuffer) }
            }

        @unknown default:
            break
        }
    }

    // MARK: - Video handling

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let screen = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Read ReplayKit orientation metadata so the output is upright.
        let orientation = videoOrientation(of: sampleBuffer)

        // Lock the encode size ONCE, from the first frame's real (oriented) aspect
        // ratio, so the stream is portrait when the screen is portrait — no squish.
        if !sizeLocked {
            let dims = orientedDimensions(of: screen, orientation: orientation)
            targetSize = settings.encodeSize(forOrientedWidth: dims.width, height: dims.height)
            sizeLocked = true
            let publisher = self.publisher
            let size = targetSize
            Task { await publisher.setOutputSize(size) }
        }

        let publisher = self.publisher

        // Fast path: facecam off AND the frame is already upright. Pass the native
        // buffer straight through; the encoder letterbox-scales it to targetSize
        // (same aspect → a clean downscale, no bars, no distortion).
        if !settings.pipEnabled, orientation == .up {
            Task { await publisher.appendVideo(sampleBuffer) }
            return
        }

        // Otherwise render into the locked canvas: this reorients the frame and/or
        // composites the facecam. The camera frame is nil when PIP is off (a purely
        // rotated frame still needs reorienting).
        let camera = settings.pipEnabled ? facecam.latest.take() : nil

        guard let composited = compositor.composite(screen: screen,
                                                     camera: camera,
                                                     targetSize: targetSize,
                                                     orientation: orientation,
                                                     corner: settings.pipCorner,
                                                     scale: settings.pipScale,
                                                     cameraPosition: settings.cameraPosition),
              let outBuffer = compositor.makeSampleBuffer(from: composited,
                                                          timingSource: sampleBuffer) else {
            // Compositing failed: fall back to the raw screen buffer.
            Task { await publisher.appendVideo(sampleBuffer) }
            return
        }

        Task { await publisher.appendVideo(outBuffer) }
    }

    /// The frame's dimensions AFTER applying the orientation transform (90°/270°
    /// rotations swap width and height).
    private func orientedDimensions(of pixelBuffer: CVPixelBuffer,
                                    orientation: CGImagePropertyOrientation) -> (width: Int, height: Int) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return (width: h, height: w)
        default:
            return (width: w, height: h)
        }
    }

    private func videoOrientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        if let attachment = CMGetAttachment(sampleBuffer,
                                            key: RPVideoSampleOrientationKey as CFString,
                                            attachmentModeOut: nil) as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: attachment.uint32Value) {
            return orientation
        }
        return .up
    }
}
