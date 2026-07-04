import AVFoundation
import CoreMedia
import Observation
import os
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import StreamCore

#if canImport(ScreenCaptureKit)
private let captureLog = Logger(subsystem: "com.joeblau.Stream", category: "screen-capture")

/// Owns the iOS 27 ScreenCaptureKit flow: system content selection, sample
/// capture, and the existing network publisher. Capture now runs in the app;
/// ReplayKit and a broadcast upload extension are not involved.
@MainActor
@Observable
final class ScreenCaptureController: NSObject {
    private(set) var isLive = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let picker = SCContentSharingPicker.shared
    @ObservationIgnored private var pendingSettings: StreamSettings?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: ScreenCaptureOutput?
    @ObservationIgnored private var publisher: (any Publisher)?
    @ObservationIgnored private var publisherTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var micVolumeObserver: DarwinSignalObserver?

    override init() {
        super.init()
        picker.add(self)
        picker.isActive = true
        micVolumeObserver = DarwinSignalObserver(name: BroadcastControl.micVolumeSignal) { [weak self] in
            Task { @MainActor [weak self] in self?.applyMicVolume() }
        }
    }

    func presentPicker(settings: StreamSettings) {
        guard stream == nil else { return }
        guard settings.isPublishable else {
            errorMessage = "Complete the connection settings before starting a stream."
            return
        }
        guard picker.isAvailable else {
            errorMessage = "Screen capture is not available on this device."
            return
        }

        pendingSettings = settings
        Task {
            await configurePreferredMicrophone(settings.preferredAudioInputUID)
            presentSystemPicker(settings: settings)
        }
    }

    private func presentSystemPicker(settings: StreamSettings) {
        guard pendingSettings != nil, stream == nil else { return }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = true
        // ScreenCaptureKit's system camera effect only supports current-app
        // capture. Full-display streams keep using our frame compositor.
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        captureLog.info("Presenting ScreenCaptureKit full-display picker")
        picker.present(using: .display)
    }

    func stop() {
        Task { await stopCapture() }
    }

    func clearError() {
        errorMessage = nil
    }

    private func makePublisher(for transport: StreamCore.StreamProtocol) -> any Publisher {
        switch transport {
        case .rtmp, .rtmps:
            RTMPPublisher()
        case .srt, .whip:
            SessionPublisher(protocol: transport)
        }
    }

    private func startCapture(with filter: SCContentFilter) async {
        if stream != nil { await stopCapture() }

        let settings = pendingSettings ?? SettingsStore().load()
        pendingSettings = nil
        guard settings.isPublishable else {
            errorMessage = "Complete the connection settings before starting a stream."
            return
        }

        let publisher = makePublisher(for: settings.selectedProtocol)
        let output = ScreenCaptureOutput(publisher: publisher, settings: settings) { [weak self] error in
            Task { @MainActor [weak self] in await self?.captureDidStop(error: error) }
        }

        let configuration = SCStreamConfiguration()
        let nativeWidth = max(2, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        let nativeHeight = max(2, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.width = nativeWidth
        configuration.height = nativeHeight
        configuration.capturesAudio = settings.includeAppAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: output.sampleQueue)
            if settings.includeAppAudio {
                try stream.addStreamOutput(output, type: .audio,
                                           sampleHandlerQueue: output.sampleQueue)
            }
            // The picker owns whether microphone capture is enabled. Registering
            // the output here makes samples available when the user turns it on.
            try stream.addStreamOutput(output, type: .microphone,
                                       sampleHandlerQueue: output.sampleQueue)

            self.publisher = publisher
            self.output = output
            self.stream = stream
            publisherTask = Task { [weak self] in
                do {
                    try await publisher.start(settings)
                } catch {
                    await self?.publisherDidFail(error)
                }
            }

            try await stream.startCapture()
            isLive = true
            publishState(true)
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { publishState(true) }
                }
            }
            captureLog.info("ScreenCaptureKit stream started")
        } catch {
            await stopCapture()
            let nsError = error as NSError
            errorMessage = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
            captureLog.error("Stream start failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
        }
    }

    private func stopCapture() async {
        let stream = self.stream
        let publisher = self.publisher
        let output = self.output

        self.stream = nil
        self.publisher = nil
        self.output = nil
        publisherTask?.cancel()
        publisherTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        isLive = false
        output?.finish()

        if let stream, stream.isCapturing {
            try? await stream.stopCapture()
        }
        if let publisher { await publisher.stop() }
        await deactivateAudioSession()
        publishState(false)
        captureLog.info("ScreenCaptureKit stream stopped")
    }

    private func captureDidStop(error: Error) async {
        // Flip the record button to "not live" immediately — before any teardown
        // await and regardless of whether the stream was already cleared — so an
        // error/background stop always reflects on the control.
        isLive = false
        guard stream != nil else { return }
        let nsError = error as NSError
        captureLog.error("Capture stopped: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
        await stopCapture()
        if nsError.code != SCStreamError.Code.userStopped.rawValue {
            errorMessage = error.localizedDescription
        }
    }

    private func publisherDidFail(_ error: Error) async {
        isLive = false
        guard stream != nil else { return }
        captureLog.error("Publisher failed: \(String(describing: error), privacy: .public)")
        await stopCapture()
        errorMessage = error.localizedDescription
    }

    private func applyMicVolume() {
        guard let publisher else { return }
        let volume = SettingsStore().load().micVolume
        output?.setMicVolume(volume)
        Task { await publisher.setMicVolume(volume) }
    }

    private func configurePreferredMicrophone(_ uid: String?) async {
        let session = AVAudioSession.sharedInstance()
        var activated = false
        for options in AudioInputProvider.bluetoothOptionLadder() {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true, options: [])
                activated = true
                break
            } catch {
                continue
            }
        }
        guard activated else {
            captureLog.warning("Could not preconfigure the preferred microphone; ScreenCaptureKit will use the system default")
            return
        }
        guard let uid,
              let input = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        do {
            try session.setPreferredInput(input)
        } catch {
            captureLog.warning("Preferred microphone route failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func deactivateAudioSession() async {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            captureLog.warning("Audio-session deactivation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func publishState(_ live: Bool) {
        BroadcastStateStore.write(BroadcastState(
            isBroadcasting: live,
            heartbeat: Date().timeIntervalSince1970
        ))
        BroadcastControl.post(BroadcastControl.stateSignal)
    }
}

extension ScreenCaptureController: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingSettings = nil
            captureLog.info("ScreenCaptureKit picker cancelled")
            await self.deactivateAudioSession()
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        let filter = UncheckedSendableBox(filter)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selectedFilter = filter.value
            captureLog.info("Picker selected content: style=\(String(describing: selectedFilter.style), privacy: .public) rect=\(String(describing: selectedFilter.contentRect), privacy: .public) scale=\(selectedFilter.pointPixelScale, privacy: .public)")
            await self.startCapture(with: selectedFilter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let error = UncheckedSendableBox(error as NSError)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingSettings = nil
            let nsError = error.value
            captureLog.error("Picker failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\(nsError.localizedDescription, privacy: .public)")
            await self.deactivateAudioSession()
            self.errorMessage = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        }
    }
}

/// ScreenCaptureKit's Objective-C observer callbacks arrive on a framework queue
/// and its reference types aren't annotated Sendable. The box transfers immutable
/// callback values into an explicit MainActor task without actor-assuming thunks.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Routes ScreenCaptureKit's serial sample callbacks into one ordered video
/// consumer and the publishers' existing ordered audio ingress.
private final class ScreenCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate,
                                         @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.joeblau.Stream.screen-capture.samples",
                                    qos: .userInteractive)

    private let publisher: any Publisher
    private let settings: StreamSettings
    private let onStopped: @Sendable (Error) -> Void
    private let micLevelMeter: ScreenCaptureMicrophoneMeter
    private let micLevelChannel = MicrophoneLevelChannel()
    private let facecam = FacecamCapture()
    private let compositor = FacecamCompositor()
    private let videoSamples: AsyncStream<CMSampleBuffer>
    private let videoContinuation: AsyncStream<CMSampleBuffer>.Continuation
    private var videoConsumer: Task<Void, Never>?

    /// Target-frame-rate pacing. SCStream on iOS delivers at the display's native
    /// refresh (up to 120 Hz on ProMotion) and offers NO `minimumFrameInterval`,
    /// so the screen callback itself must throttle down to `settings.frameRate` —
    /// otherwise the encoder is flooded (irregular pacing + CPU/thermal spikes that
    /// stutter both video and audio). Touched only on the serial `sampleQueue`.
    private let targetFrameInterval: CMTime
    private var nextVideoDeadline: CMTime = .invalid

    init(publisher: any Publisher,
         settings: StreamSettings,
         onStopped: @escaping @Sendable (Error) -> Void) {
        self.publisher = publisher
        self.settings = settings
        self.onStopped = onStopped
        micLevelMeter = ScreenCaptureMicrophoneMeter(gain: settings.micVolume)
        targetFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.frameRate)))
        (videoSamples, videoContinuation) = AsyncStream.makeStream(
            of: CMSampleBuffer.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        super.init()
        if settings.pipEnabled { facecam.start(with: settings) }
        videoConsumer = Task { [videoSamples, publisher, settings] in
            var targetSize: CGSize?
            for await sampleBuffer in videoSamples {
                guard sampleBuffer.isValid,
                      sampleBuffer.dataReadiness == .ready,
                      let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                if targetSize == nil {
                    let width = CVPixelBufferGetWidth(image)
                    let height = CVPixelBufferGetHeight(image)
                    let target = settings.encodeSize(forOrientedWidth: width, height: height)
                    await publisher.setOutputSize(target, nativeShortEdge: min(width, height))
                    targetSize = target
                }
                if settings.pipEnabled, let targetSize,
                   let camera = self.facecam.latest.take(),
                   let composited = self.compositor.composite(
                       screen: image,
                       camera: camera,
                       targetSize: targetSize,
                       orientation: .up,
                       corner: settings.pipCorner,
                       scale: settings.pipScale,
                       cameraPosition: settings.cameraPosition
                   ),
                   let output = self.compositor.makeSampleBuffer(
                       from: composited,
                       timingSource: sampleBuffer
                   ) {
                    await publisher.appendVideo(output)
                } else {
                    await publisher.appendVideo(sampleBuffer)
                }
            }
        }
    }

    func finish() {
        micLevelChannel.publish(0)
        facecam.stop()
        videoContinuation.finish()
        videoConsumer?.cancel()
        videoConsumer = nil
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        switch type {
        case .screen:
            // Downsample the native-refresh feed to the target frame rate by PTS
            // deadline: emit the first frame at/after each deadline, then advance
            // by one interval; re-anchor after a stall so a gap doesn't burst.
            let pts = sampleBuffer.presentationTimeStamp
            if pts.isValid {
                if nextVideoDeadline.isValid, CMTimeCompare(pts, nextVideoDeadline) < 0 {
                    return   // arrived before the next target-fps slot — drop it
                }
                let advanced = CMTimeAdd(nextVideoDeadline.isValid ? nextVideoDeadline : pts,
                                         targetFrameInterval)
                nextVideoDeadline = CMTimeCompare(advanced, pts) > 0
                    ? advanced
                    : CMTimeAdd(pts, targetFrameInterval)
            }
            videoContinuation.yield(sampleBuffer)
        case .audio:
            if settings.includeAppAudio { publisher.enqueueApp(sampleBuffer) }
        case .microphone:
            if let level = micLevelMeter.measure(sampleBuffer) {
                micLevelChannel.publish(level)
            }
            publisher.enqueueMic(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStopped(error)
    }

    func setMicVolume(_ volume: Double) {
        micLevelMeter.setGain(volume)
    }
}

/// Computes a throttled post-gain RMS level from ScreenCaptureKit microphone
/// buffers for the live meter in Settings.
private final class ScreenCaptureMicrophoneMeter: @unchecked Sendable {
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

        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription) else { return nil }
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
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else { return nil }

        var sumOfSquares = 0.0
        var sampleCount = 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
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
#else
/// ScreenCaptureKit's iOS 27 beta module is device-only. Keep previews and the
/// simulator buildable while making the hardware requirement explicit at runtime.
@MainActor
@Observable
final class ScreenCaptureController {
    private(set) var isLive = false
    private(set) var errorMessage: String?

    func presentPicker(settings: StreamSettings) {
        errorMessage = "Screen capture requires a physical iOS 27 device."
    }

    func stop() {}

    func clearError() {
        errorMessage = nil
    }
}
#endif
