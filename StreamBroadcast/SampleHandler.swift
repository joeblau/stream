import ReplayKit
import AVFoundation
import CoreMedia
import VideoToolbox
import StreamCore
import os
import os.lock

/// Filterable in Console.app / `log stream` with: subsystem:com.joeblau.Stream
private let broadcastLog = Logger(subsystem: "com.joeblau.Stream", category: "broadcast")

/// Principal class of the broadcast upload extension. Loads settings from the
/// App Group, configures the audio session (incl. the persisted Bluetooth mic),
/// optionally starts the facecam, and routes ReplayKit buffers into the
/// `RTMPPublisher` actor.
///
/// `@unchecked Sendable`: the class itself holds only immutable/actor-isolated
/// or lock-guarded collaborators; per buffer it spawns `Task { await ... }`.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    private let publisher: any Publisher
    private let facecam = FacecamCapture()
    private let compositor = FacecamCompositor()
    private let settings: StreamSettings
    private let micLevelMeter: MicrophoneLevelMeter
    private let micLevelChannel = MicrophoneLevelChannel()
    private let audioSession = AudioSessionController()
    private let admission = SampleAdmissionState()
    private let videoGate = InFlightSampleGate()
    private let memoryMonitor = MemoryPressureMonitor()

    /// Encode dimensions, locked once from the first screen frame so the stream
    /// matches the device's real orientation/aspect. Touched only on the serial
    /// ReplayKit sample-delivery thread.
    private var targetSize: CGSize = .zero
    private var sizeLocked = false

    /// Cross-process control: observes the app's "End Stream" signal, and a
    /// heartbeat that proves to the app the broadcast is still alive. `hasEnded`
    /// makes teardown run exactly once across the app-stop and system-stop paths.
    private var stopObserver: DarwinSignalObserver?
    private var micVolumeObserver: DarwinSignalObserver?
    private var heartbeatTask: Task<Void, Never>?
    private var hasEnded = false

    override init() {
        let settings = SettingsStore().load()
        self.settings = settings
        self.micLevelMeter = MicrophoneLevelMeter(gain: settings.micVolume)
        // RTMP/RTMPS use the dedicated publisher; SRT/WHIP use the unified
        // StreamSession publisher. Chosen once, from the persisted protocol.
        switch settings.selectedProtocol {
        case .rtmp, .rtmps:
            self.publisher = RTMPPublisher()
        case .srt, .whip:
            self.publisher = SessionPublisher(protocol: settings.selectedProtocol)
        }
        super.init()
    }

    // MARK: - Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        broadcastLog.info("Broadcast starting: publishable=\(self.settings.isPublishable ? "yes" : "no", privacy: .public), backup=\(self.settings.backupEnabled ? "on" : "off", privacy: .public), quality=\(self.settings.backupQuality.rawValue, privacy: .public)")

        admission.setAccepting(true)
        micLevelChannel.publish(0)
        memoryMonitor.start()

        // Publish live state and let the app's "End Stream" button reach us — the
        // extension is the only process that can stop itself. The heartbeat lets
        // the app tell a running broadcast from a jetsam-killed one.
        Self.publishState(true)
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                BroadcastStateStore.write(BroadcastState(
                    isBroadcasting: true,
                    heartbeat: Date().timeIntervalSince1970))
            }
        }
        stopObserver = DarwinSignalObserver(name: BroadcastControl.stopSignal) { [weak self] in
            self?.endFromApp()
        }
        micVolumeObserver = DarwinSignalObserver(name: BroadcastControl.micVolumeSignal) { [weak self] in
            self?.applyMicVolumeFromSettings()
        }

        // Configure and continuously supervise the session so calls, media-service
        // resets, and Bluetooth route changes do not permanently stall the mic.
        // `start` no longer throws: an initial failure (e.g. a broadcast started
        // during a phone call) keeps the observers installed and retries, so the
        // mic arrives when the interruption ends.
        audioSession.start(with: settings)

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
                // Do not leave the mixer/audio session alive while ReplayKit is
                // propagating the startup failure back to the system UI.
                self.admission.setAccepting(false)
                self.micLevelChannel.publish(0)
                self.heartbeatTask?.cancel()
                await publisher.stop()
                self.audioSession.stop()
                Self.publishState(false)
                self.finishBroadcastWithError(error)
            }
        }
    }

    override func broadcastPaused() {
        // Stop admission before the asynchronous network teardown. Holding an idle
        // publisher open lets ingests retire the NetStream while TCP stays alive.
        admission.setAccepting(false)
        micLevelChannel.publish(0)
        facecam.stop()
        memoryMonitor.stop()
        let publisher = self.publisher
        Task { await publisher.pause() }
    }

    override func broadcastResumed() {
        // Re-publish first, then admit ReplayKit buffers. The publisher rebases the
        // first post-resume timestamps so HaishinKit does not synthesize the entire
        // paused wall-clock gap as audio silence.
        let publisher = self.publisher
        let admission = self.admission
        let facecam = self.facecam
        let settings = self.settings
        Task {
            await publisher.resume()
            if settings.pipEnabled { facecam.start(with: settings) }
            admission.setAccepting(true)
        }
    }

    override func broadcastFinished() {
        guard !hasEnded else { return }
        hasEnded = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopObserver = nil
        micVolumeObserver = nil
        admission.setAccepting(false)
        micLevelChannel.publish(0)
        facecam.stop()
        memoryMonitor.stop()
        // Release the mic/HFP route deterministically BEFORE the async network
        // teardown: iOS may suspend the extension the moment this callback
        // returns, and a deferred stop often never ran, leaving the session
        // holding the Bluetooth mic into the next broadcast.
        audioSession.stop()
        let publisher = self.publisher
        Task {
            await publisher.stop()
            Self.publishState(false)
        }
    }

    /// Ends the broadcast in response to the app's "End Stream" button. The
    /// extension is the only party that can stop itself, and
    /// `finishBroadcastWithError` is the only API to do it (so iOS shows a brief
    /// "ended" notice). The pipeline is torn down first with the manual-stop flag
    /// set, so it cannot auto-reconnect after the user has ended the stream.
    private func endFromApp() {
        guard !hasEnded else { return }
        hasEnded = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopObserver = nil
        micVolumeObserver = nil
        admission.setAccepting(false)
        micLevelChannel.publish(0)
        facecam.stop()
        memoryMonitor.stop()
        // Deterministic mic release, same rationale as broadcastFinished().
        audioSession.stop()
        let publisher = self.publisher
        Task {
            await publisher.stop()
            Self.publishState(false)
            await MainActor.run {
                self.finishBroadcastWithError(NSError(
                    domain: "com.joeblau.Stream.Broadcast",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Broadcast ended."]))
            }
        }
    }

    /// Writes the shared liveness state and pings the app to re-read it.
    private static func publishState(_ live: Bool) {
        BroadcastStateStore.write(BroadcastState(
            isBroadcasting: live,
            heartbeat: Date().timeIntervalSince1970))
        BroadcastControl.post(BroadcastControl.stateSignal)
    }

    /// The app's Mic Volume slider changed; re-read the persisted level and apply
    /// it to the running mixer without interrupting the stream.
    private func applyMicVolumeFromSettings() {
        let volume = SettingsStore().load().micVolume
        micLevelMeter.setGain(volume)
        let publisher = self.publisher
        Task { await publisher.setMicVolume(volume) }
    }

    // MARK: - Sample routing

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard admission.isAccepting else { return }

        switch sampleBufferType {
        case .video:
            // Drain the CoreImage/CoreMedia compositing transients immediately: in
            // the ~50 MB extension budget, autoreleased CIImages and pixel/sample
            // buffers piling up across frames until the run loop drains its pool is
            // a primary jetsam trigger.
            autoreleasepool { handleVideo(sampleBuffer) }

        case .audioMic:
            if let level = micLevelMeter.measure(sampleBuffer) {
                micLevelChannel.publish(level)
            }
            // Enqueue SYNCHRONOUSLY here on ReplayKit's serial thread — FIFO and
            // ordered. A Task-per-buffer had no ordering guarantee, so mic buffers
            // reached HaishinKit's ring buffer out of PTS order → silence-fill +
            // swapped PCM = choppy audio. The publisher's single consumer drains
            // each buffer in order. Never dropped (buffers are a few KB).
            if sampleBuffer.dataReadiness == .ready {
                publisher.enqueueMic(sampleBuffer)
            }

        case .audioApp:
            if settings.includeAppAudio, sampleBuffer.dataReadiness == .ready {
                publisher.enqueueApp(sampleBuffer)
            }

        @unknown default:
            break
        }
    }

    // MARK: - Video handling

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // This bound sits before compositing and before actor submission, so at
        // most one ReplayKit IOSurface is retained outside the pipeline.
        guard videoGate.tryAcquire() else { return }
        guard let screen = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            videoGate.release()
            return
        }

        // Read ReplayKit orientation metadata so the output is upright.
        let orientation = videoOrientation(of: sampleBuffer)
        var configuration: (CGSize, Int)?

        // Lock the encode size ONCE, from the first frame's real (oriented) aspect
        // ratio, so the stream is portrait when the screen is portrait — no squish.
        if !sizeLocked {
            let dims = orientedDimensions(of: screen, orientation: orientation)
            targetSize = settings.encodeSize(forOrientedWidth: dims.width, height: dims.height)
            sizeLocked = true
            configuration = (targetSize, min(dims.width, dims.height))
        }

        // Under memory pressure, shed the facecam compositor entirely — its BGRA
        // canvas buffers are the ~2x per-frame memory multiplier — and pass the raw
        // screen through, so the stream stays up (screen-only) instead of the
        // extension being jetsam-killed. Restored automatically when headroom recovers.
        let pipActive = settings.pipEnabled && !memoryMonitor.isUnderPressure

        // Fast path: facecam off AND the frame is already upright. Pass the native
        // buffer straight through; the encoder letterbox-scales it to targetSize
        // (same aspect → a clean downscale, no bars, no distortion).
        if !pipActive, orientation == .up {
            submitVideo(sampleBuffer, configuration: configuration)
            return
        }

        // Otherwise render into the locked canvas: this reorients the frame and/or
        // composites the facecam. The camera frame is nil when PIP is off (a purely
        // rotated frame still needs reorienting).
        let camera = pipActive ? facecam.latest.take() : nil

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
            submitVideo(sampleBuffer, configuration: configuration)
            return
        }

        submitVideo(outBuffer, configuration: configuration)
    }

    /// Submits exactly one video sample at a time. Configuration and the first
    /// append share a task so actor scheduling cannot drop/reorder the first frame.
    private func submitVideo(_ sampleBuffer: CMSampleBuffer,
                             configuration: (CGSize, Int)? = nil) {
        let publisher = self.publisher
        let gate = self.videoGate
        Task {
            if let configuration {
                await publisher.setOutputSize(configuration.0,
                                              nativeShortEdge: configuration.1)
            }
            await publisher.appendVideo(sampleBuffer)
            gate.release()
        }
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

/// Computes a throttled post-gain RMS level from ReplayKit's linear PCM mic
/// buffers. Work is bounded to one sample buffer every 100 ms.
private final class MicrophoneLevelMeter: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var lastMeasurementAt: UInt64 = 0
    private var gain: Float

    init(gain: Double) {
        self.gain = Float(max(0, min(gain, 2)))
    }

    func setGain(_ gain: Double) {
        os_unfair_lock_lock(&lock)
        self.gain = Float(max(0, min(gain, 2)))
        os_unfair_lock_unlock(&lock)
    }

    func measure(_ sampleBuffer: CMSampleBuffer) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(&lock)
        guard now &- lastMeasurementAt >= 100_000_000 else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        lastMeasurementAt = now
        let gain = self.gain
        os_unfair_lock_unlock(&lock)

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = description.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var listSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr, listSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let audioBufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else { return nil }

        var sumOfSquares = 0.0
        var sampleCount = 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            if isFloat, asbd.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let value = Double(samples[index])
                    sumOfSquares += value * value
                }
                sampleCount += count
            } else if asbd.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let value = Double(samples[index]) / Double(Int16.max)
                    sumOfSquares += value * value
                }
                sampleCount += count
            } else if asbd.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let value = Double(samples[index]) / Double(Int32.max)
                    sumOfSquares += value * value
                }
                sampleCount += count
            }
        }
        guard sampleCount > 0 else { return nil }

        let rms = min(1, sqrt(sumOfSquares / Double(sampleCount)) * Double(gain))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Float(max(0, min(1, (decibels + 60) / 60)))
    }
}

/// Thread-safe lifecycle admission because ReplayKit lifecycle callbacks and
/// sample delivery are not documented to share a queue.
private final class SampleAdmissionState: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var accepting = false

    var isAccepting: Bool {
        os_unfair_lock_lock(&lock)
        let value = accepting
        os_unfair_lock_unlock(&lock)
        return value
    }

    func setAccepting(_ value: Bool) {
        os_unfair_lock_lock(&lock)
        accepting = value
        os_unfair_lock_unlock(&lock)
    }
}

/// A one-slot nonblocking gate. Samples are dropped instead of waiting because
/// retaining ReplayKit buffers while the extension is backpressured causes jetsam.
private final class InFlightSampleGate: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var occupied = false

    func tryAcquire() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    func release() {
        os_unfair_lock_lock(&lock)
        occupied = false
        os_unfair_lock_unlock(&lock)
    }
}

/// Watches the extension's remaining memory headroom (`os_proc_available_memory`)
/// and flips an "under pressure" flag with hysteresis, so the video path can shed
/// the facecam compositor — its BGRA canvas buffers are the biggest per-frame
/// allocation — BEFORE the ~50MB jetsam limit kills the extension. Also logs the
/// available headroom periodically so the thresholds can be tuned on device.
final class MemoryPressureMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.joeblau.Stream", category: "memory")
    /// Shed load when fewer than this many bytes remain before the jetsam limit.
    /// Raised from 12→16 MB to shed EARLIER: capturing a heavier off-app screen
    /// (Safari video, a game) spikes per-frame allocation fast, so start shedding
    /// with more headroom to spare before the ~50 MB jetsam kill.
    private static let shedBelow: UInt = 16 * 1024 * 1024
    /// Restore load only after headroom climbs back above this (hysteresis).
    /// Kept a wide gap above `shedBelow` so shedding does not flap frame to frame.
    private static let recoverAbove: UInt = 24 * 1024 * 1024

    private var lock = os_unfair_lock_s()
    private var underPressure = false
    private var task: Task<Void, Never>?

    var isUnderPressure: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return underPressure
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.sample(shouldLog: tick % 4 == 0)
                tick &+= 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        os_unfair_lock_lock(&lock)
        underPressure = false
        os_unfair_lock_unlock(&lock)
    }

    private func sample(shouldLog: Bool) {
        let available = UInt(os_proc_available_memory())
        // 0 means the platform can't report (e.g. Simulator) — never false-trip.
        guard available > 0 else { return }
        os_unfair_lock_lock(&lock)
        let was = underPressure
        if available < Self.shedBelow {
            underPressure = true
        } else if available > Self.recoverAbove {
            underPressure = false
        }
        let now = underPressure
        os_unfair_lock_unlock(&lock)

        let mb = available / (1024 * 1024)
        if now != was {
            Self.log.error("Memory pressure \(now ? "ON — shedding facecam" : "cleared", privacy: .public); available=\(mb)MB")
        } else if shouldLog {
            Self.log.info("Memory available=\(mb)MB (pressure=\(now, privacy: .public))")
        }
    }
}
