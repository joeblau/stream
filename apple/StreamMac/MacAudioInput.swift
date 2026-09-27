import AVFoundation
import Combine
import CoreMedia
import os

private let audioInputLog = Logger(subsystem: "com.joeblau.StreamMac", category: "mac-audio-input")

/// Captures the microphone with an `AVCaptureSession` + `AVCaptureAudioDataOutput`
/// (macOS has no `AVAudioSession`), forwards LPCM `CMSampleBuffer`s to the
/// publisher, enumerates audio input devices, and publishes a smoothed 0...1
/// RMS meter level at ~10 Hz for SwiftUI.
@MainActor
final class MacAudioInput: ObservableObject {
    /// Smoothed 0...1 microphone level. Published on change only, at ~10 Hz.
    @Published private(set) var level: Float = 0
    /// Audio capture devices from the most recent `refreshDevices()`.
    @Published private(set) var devices: [AVCaptureDevice] = []

    /// Called with each microphone sample buffer, hopped to the main actor.
    var onMicSample: ((CMSampleBuffer) -> Void)?

    private var session: AVCaptureSession?
    /// Retained for the capture's lifetime: `AVCaptureAudioDataOutput` holds its
    /// sample-buffer delegate weakly.
    private var outputShim: AudioCaptureShim?
    private var activeDevice: AVCaptureDevice?
    private var lastLevelPublishAt: UInt64 = 0

    /// Notification tokens. `nonisolated(unsafe)` so `deinit` (nonisolated on a
    /// @MainActor type) can remove them; tokens are safe to touch there.
    private nonisolated(unsafe) var deviceObservers: [NSObjectProtocol] = []

    /// Session start/stop off the main actor: `startRunning()` blocks.
    private let sessionQueue = DispatchQueue(label: "com.joeblau.StreamMac.mic-session",
                                             qos: .userInitiated)
    /// Serial queue for `AVCaptureAudioDataOutput` callbacks.
    private let sampleQueue = DispatchQueue(label: "com.joeblau.StreamMac.mic-samples",
                                            qos: .userInitiated)

    init() {
        refreshDevices()
        let center = NotificationCenter.default
        deviceObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDeviceChange() }
        })
        deviceObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDeviceChange() }
        })
    }

    deinit {
        deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Starts capture from the system default audio input device.
    func start() {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            audioInputLog.error("No default audio input device")
            return
        }
        start(device: device)
    }

    /// Starts capture from a specific device (one of `devices`).
    func start(device: AVCaptureDevice) {
        stop()
        Task { [weak self] in
            guard await Self.requestMicrophoneAccess() else {
                audioInputLog.error("Microphone permission denied")
                return
            }
            self?.configureAndStart(device: device)
        }
    }

    func stop() {
        guard let session else {
            level = 0
            return
        }
        self.session = nil
        outputShim = nil
        activeDevice = nil
        let box = UncheckedSendableBox(session)
        sessionQueue.async { box.value.stopRunning() }
        level = 0
        lastLevelPublishAt = 0
    }

    /// Re-enumerates audio input devices (built-in mic plus wired/USB inputs).
    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = discovery.devices
    }

    // MARK: - Private

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func configureAndStart(device: AVCaptureDevice) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                audioInputLog.error("Cannot add audio input for \(device.localizedName, privacy: .public)")
                session.commitConfiguration()
                return
            }
            session.addInput(input)
        } catch {
            audioInputLog.error("Audio input failed: \(error.localizedDescription, privacy: .public)")
            session.commitConfiguration()
            return
        }

        let output = AVCaptureAudioDataOutput()
        let shim = AudioCaptureShim { [weak self] sample, rawLevel in
            Task { @MainActor in
                guard let self else { return }
                self.onMicSample?(sample.value)
                if let rawLevel { self.publishLevel(rawLevel) }
            }
        }
        output.setSampleBufferDelegate(shim, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            audioInputLog.error("Cannot add audio data output")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        outputShim = shim
        activeDevice = device

        let box = UncheckedSendableBox(session)
        sessionQueue.async { box.value.startRunning() }
        audioInputLog.info("Mic capture started: \(device.localizedName, privacy: .public)")
    }

    /// Attack/decay smoothing, gated to ~10 Hz so SwiftUI isn't invalidated per
    /// audio buffer (~47/s). Skips the write when the level didn't change.
    private func publishLevel(_ raw: Float) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastLevelPublishAt >= 100_000_000 else { return }
        lastLevelPublishAt = now
        var next = raw >= level ? level * 0.3 + raw * 0.7 : max(raw, level * 0.82)
        if next < 0.005 { next = 0 }
        if next != level { level = next }
    }

    private func handleDeviceChange() {
        refreshDevices()
        if let activeDevice, !activeDevice.isConnected {
            // The live input was unplugged; the session stops delivering, so
            // don't leave a frozen non-zero meter on screen.
            level = 0
        }
    }
}

/// Transfers non-Sendable callback values (CMSampleBuffer, AVCaptureSession)
/// across the MainActor hop / session queue without actor-assuming thunks.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Receives `AVCaptureAudioDataOutput` buffers on the serial sample queue,
/// computes a throttled RMS level, and forwards both into a MainActor closure.
private final class AudioCaptureShim: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
                                      @unchecked Sendable {
    private let meter = MicLevelMeter()
    private let handler: @Sendable (UncheckedSendableBox<CMSampleBuffer>, Float?) -> Void

    init(handler: @escaping @Sendable (UncheckedSendableBox<CMSampleBuffer>, Float?) -> Void) {
        self.handler = handler
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        handler(UncheckedSendableBox(sampleBuffer), meter.measure(sampleBuffer))
    }
}

/// Throttled (~10 Hz) RMS level for LPCM sample buffers. Returns nil for
/// non-PCM formats — metering is skipped rather than crashing on formats it
/// can't read — and for buffers inside the throttle window.
private final class MicLevelMeter: @unchecked Sendable {
    private var lastMeasurementAt: UInt64 = 0

    func measure(_ sampleBuffer: CMSampleBuffer) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastMeasurementAt >= 100_000_000 else { return nil }
        lastMeasurementAt = now

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

        let rms = min(1, sqrt(sumOfSquares / Double(sampleCount)))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Float(max(0, min(1, (decibels + 60) / 60)))
    }
}
