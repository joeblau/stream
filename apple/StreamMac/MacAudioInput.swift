import AVFoundation
import Combine
import CoreMedia
import StreamCore
import os

private let audioInputLog = Logger(subsystem: "com.joeblau.StreamMac", category: "mac-audio-input")

/// Captures the microphone(s) with `AVCaptureSession` + `AVCaptureAudioDataOutput`
/// (macOS has no `AVAudioSession`), forwards LPCM `CMSampleBuffer`s to the
/// audio engine, enumerates audio input devices, and publishes a smoothed
/// 0...1 RMS meter level at ~10 Hz for SwiftUI.
///
/// A05 (issue #84): beyond the DEFAULT microphone (the `.microphone(deviceUID:
/// nil)` channel — `start()`/`start(device:)` below, unchanged), any number of
/// ADDITIONAL input devices can capture simultaneously, each into its own mix
/// channel `.microphone(deviceUID: <uniqueID>)`. Design: ONE AVCaptureSession
/// PER DEVICE rather than one shared session with N inputs — independent
/// start/stop and per-device sample queues keep a failing or unplugged device
/// from touching any other channel's capture (the issue's "hot-unplug affects
/// only the selected channel"), and no cross-device clock coupling is needed
/// because the mix engine positions every buffer on the shared host clock by
/// its capture PTS (the drift correction). Each additional device's buffers
/// first pass through its `AudioDeviceChannelMapper` (the audio-interface
/// hardware-channel mapping), then hop straight to the engine's nonisolated
/// ingest — no main-actor bounce on the audio path.
///
/// C10 (issue #79) hot-plug: availability change notifications arrive through
/// the `DeviceMonitor` (the ONE availability watcher) via
/// `noteAudioDeviceConnected/Disconnected`. An unplugged enabled device's
/// capture stops honestly and its UID reports in `missingAdditionalDeviceUIDs`;
/// capture resumes only when the SAME uniqueID returns — a different device is
/// never substituted silently (relink is the explicit settings/mixer path).
@MainActor
final class MacAudioInput: ObservableObject {
    /// Smoothed 0...1 microphone level. Published on change only, at ~10 Hz.
    @Published private(set) var level: Float = 0
    /// Audio capture devices from the most recent `refreshDevices()`.
    @Published private(set) var devices: [AVCaptureDevice] = []
    /// Human-readable description of the last start failure (missing device,
    /// permission denial, session configuration failure) or a mid-capture
    /// device disconnect (C10, issue #79). Cleared on a successful start.
    /// Part of the S05 per-source error surface (issue #73).
    @Published private(set) var errorMessage: String?

    /// A05: the enabled additional-input selections from the last
    /// `startAdditionalInputs` (identity + hardware-channel mapping), for the
    /// mixer's expected strips and the settings input list.
    @Published private(set) var additionalInputs: [AudioInputSelection] = []
    /// A05: enabled additional devices that are currently UNPLUGGED. The
    /// mixer shows those channels inactive with relink controls; the same
    /// uniqueID returning restarts capture automatically.
    @Published private(set) var missingAdditionalDeviceUIDs: Set<String> = []
    /// A05: last-known display names by device UID — including unplugged
    /// enabled devices, so missing channels and settings rows stay named.
    @Published private(set) var deviceNamesByUID: [String: String] = [:]
    /// A05: hardware input channel counts by device UID (for the
    /// channel-mapping UI; 1 = plain mono mic, no mapping needed).
    @Published private(set) var deviceChannelCounts: [String: Int] = [:]
    /// A05: per-device start/configuration failures, by device UID.
    @Published private(set) var additionalInputErrors: [String: String] = [:]

    /// Called with each microphone sample buffer, hopped to the main actor.
    var onMicSample: ((CMSampleBuffer) -> Void)?
    /// A01 (issue #82): real-time mic hand-off that fires DIRECTLY on the
    /// capture sample queue — no main-actor hop — so the audio engine's
    /// format conversion and insert chain never run on the main thread.
    /// The meter/UI path above is unaffected.
    var onMicSampleOffMain: (@Sendable (CMSampleBuffer) -> Void)?
    /// A05 (issue #84): the same off-main hand-off for ADDITIONAL input
    /// devices, carrying the device's stable `uniqueID` so the engine can
    /// enqueue onto `.microphone(deviceUID:)`. Buffers are already
    /// channel-mapped (`AudioDeviceChannelMapper`) on the capture queue.
    var onDeviceSampleOffMain: (@Sendable (String, CMSampleBuffer) -> Void)?

    private var session: AVCaptureSession?
    /// Retained for the capture's lifetime: `AVCaptureAudioDataOutput` holds its
    /// sample-buffer delegate weakly.
    private var outputShim: AudioCaptureShim?
    private var activeDevice: AVCaptureDevice?
    private var lastLevelPublishAt: UInt64 = 0
    /// C10 (issue #79): the input the user/pipeline last chose. Survives an
    /// unplug-driven stop so capture can resume when the SAME device returns
    /// — a different device is never substituted silently.
    private var lastRequestedDeviceUID: String?
    /// C10: true only between "the live input was unplugged" and its return
    /// (or an explicit restart). Gates hot-plug recovery so an intentional
    /// pipeline stop never resurrects mic capture on a later device connect.
    private var isAwaitingDeviceReturn = false

    /// A05: live additional-device captures, keyed by device uniqueID.
    private var deviceCaptures: [String: AdditionalMicCapture] = [:]
    /// A05: armed only between `startAdditionalInputs` and `stop`, so a
    /// device connect during an intentional pipeline stop never starts
    /// capture (the same gate `isAwaitingDeviceReturn` gives the default mic).
    private var additionalInputsArmed = false

    /// Session start/stop off the main actor: `startRunning()` blocks.
    private let sessionQueue = DispatchQueue(label: "com.joeblau.StreamMac.mic-session",
                                             qos: .userInitiated)
    /// Serial queue for `AVCaptureAudioDataOutput` callbacks.
    private let sampleQueue = DispatchQueue(label: "com.joeblau.StreamMac.mic-samples",
                                            qos: .userInitiated)

    init() {
        refreshDevices()
    }

    /// Starts capture from the system default audio input device.
    func start() {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            errorMessage = "No audio input device is available."
            audioInputLog.error("No default audio input device")
            return
        }
        start(device: device)
    }

    /// Starts capture from a specific device (one of `devices`).
    func start(device: AVCaptureDevice) {
        stopDefaultCapture()
        lastRequestedDeviceUID = device.uniqueID
        isAwaitingDeviceReturn = false
        Task { [weak self] in
            guard await Self.requestMicrophoneAccess() else {
                self?.errorMessage = "Microphone access is disabled for StreamMac. Enable it in System Settings > Privacy & Security > Microphone."
                audioInputLog.error("Microphone permission denied")
                return
            }
            self?.configureAndStart(device: device)
        }
    }

    /// Full teardown (pipeline stop): the default mic AND every additional
    /// input device.
    func stop() {
        stopDefaultCapture()
        stopAdditionalInputs()
    }

    /// Stops only the default mic's capture — restarting it must not tear
    /// down the additional devices' captures (A05).
    private func stopDefaultCapture() {
        isAwaitingDeviceReturn = false
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
        // A05: remember names (a later-unplugged enabled device stays named)
        // and read each device's hardware input channel count from its
        // formats — the channel-mapping UI's option list.
        var names = deviceNamesByUID
        var counts: [String: Int] = [:]
        for device in devices {
            names[device.uniqueID] = device.localizedName
            counts[device.uniqueID] = Self.inputChannelCount(of: device)
        }
        deviceNamesByUID = names
        deviceChannelCounts = counts
    }

    // MARK: - A05 additional input devices (issue #84)

    /// Arms and reconciles additional-device capture with the enabled
    /// selections from settings. Idempotent: called at pipeline start and on
    /// every settings apply; it starts captures for newly enabled/connected
    /// devices, stops captures for disabled ones, and live-updates the
    /// hardware-channel mapping of captures that keep running.
    /// `excludingDeviceUID` guards against double capture: the device the
    /// DEFAULT mic channel already uses (the legacy preferred input) must
    /// never also open as its own channel.
    func startAdditionalInputs(_ selections: [AudioInputSelection],
                               excludingDeviceUID: String? = nil) {
        additionalInputsArmed = true
        additionalInputs = selections.filter {
            $0.isEnabled && $0.deviceUID != excludingDeviceUID
        }
        var names = deviceNamesByUID
        for selection in selections {
            if let device = devices.first(where: { $0.uniqueID == selection.deviceUID }) {
                names[selection.deviceUID] = device.localizedName
            }
        }
        deviceNamesByUID = names
        reconcileAdditionalCaptures()
    }

    /// Stops every additional-device capture (pipeline stop / settings
    /// teardown) and disarms hot-plug recovery. The SELECTIONS are kept —
    /// they are settings state, and the next `startAdditionalInputs`
    /// re-arms them.
    func stopAdditionalInputs() {
        additionalInputsArmed = false
        for (uid, capture) in Array(deviceCaptures) {
            let box = UncheckedSendableBox(capture.session)
            sessionQueue.async { box.value.stopRunning() }
            deviceCaptures[uid] = nil
            audioInputLog.info("Additional mic capture stopped: \(uid, privacy: .public)")
        }
        missingAdditionalDeviceUIDs = []
        additionalInputErrors = [:]
    }

    /// Starts/stops per-device captures to match `additionalInputs` ∩
    /// connected devices, and refreshes the missing set. Runs on every
    /// arming, settings apply, and device hot-plug.
    private func reconcileAdditionalCaptures() {
        let enabled = additionalInputs
        let enabledUIDs = Set(enabled.map(\.deviceUID))

        // Stopped being enabled (or disarmed): tear the capture down.
        for (uid, capture) in Array(deviceCaptures) where !additionalInputsArmed || !enabledUIDs.contains(uid) {
            let box = UncheckedSendableBox(capture.session)
            sessionQueue.async { box.value.stopRunning() }
            deviceCaptures[uid] = nil
            additionalInputErrors[uid] = nil
        }

        guard additionalInputsArmed else {
            missingAdditionalDeviceUIDs = []
            return
        }

        var missing: Set<String> = []
        for selection in enabled {
            let uid = selection.deviceUID
            guard let device = devices.first(where: { $0.uniqueID == uid }),
                  device.isConnected else {
                // Enabled but unplugged: report honestly; the same uniqueID
                // returning restarts capture on the next reconcile.
                missing.insert(uid)
                if let capture = deviceCaptures[uid] {
                    let box = UncheckedSendableBox(capture.session)
                    sessionQueue.async { box.value.stopRunning() }
                    deviceCaptures[uid] = nil
                    audioInputLog.error("Additional audio input disconnected: \(uid, privacy: .public)")
                }
                continue
            }
            if let capture = deviceCaptures[uid] {
                // Live mapping update — no capture restart.
                capture.mapper.setMapping(selection.mapping)
            } else {
                startAdditionalCapture(device: device, mapping: selection.mapping)
            }
        }
        missingAdditionalDeviceUIDs = missing
    }

    private func startAdditionalCapture(device: AVCaptureDevice,
                                        mapping: AudioInputMapping) {
        let uid = device.uniqueID
        Task { [weak self] in
            guard await Self.requestMicrophoneAccess() else {
                self?.additionalInputErrors[uid] = "Microphone access is disabled for StreamMac. Enable it in System Settings > Privacy & Security > Microphone."
                audioInputLog.error("Microphone permission denied (additional input)")
                return
            }
            self?.configureAndStartAdditional(device: device, mapping: mapping)
        }
    }

    private func configureAndStartAdditional(device: AVCaptureDevice,
                                             mapping: AudioInputMapping) {
        let uid = device.uniqueID
        guard deviceCaptures[uid] == nil else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                additionalInputErrors[uid] = "Cannot capture audio from \(device.localizedName)."
                audioInputLog.error("Cannot add audio input for \(device.localizedName, privacy: .public)")
                session.commitConfiguration()
                return
            }
            session.addInput(input)
        } catch {
            additionalInputErrors[uid] = "Audio input failed: \(error.localizedDescription)"
            audioInputLog.error("Additional audio input failed: \(error.localizedDescription, privacy: .public)")
            session.commitConfiguration()
            return
        }

        let mapper = AudioDeviceChannelMapper(mapping: mapping)
        let offMain = onDeviceSampleOffMain
        let captureQueue = DispatchQueue(label: "com.joeblau.StreamMac.mic-samples.\(uid)",
                                         qos: .userInitiated)
        let shim = AdditionalAudioCaptureShim { sample in
            // Channel mapping runs here, on the device's own sample queue,
            // then straight to the engine — never the main thread.
            offMain?(uid, mapper.process(sample.value))
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(shim, queue: captureQueue)
        guard session.canAddOutput(output) else {
            additionalInputErrors[uid] = "Cannot capture audio from \(device.localizedName)."
            audioInputLog.error("Cannot add audio data output (additional input)")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        deviceCaptures[uid] = AdditionalMicCapture(session: session,
                                                   shim: shim,
                                                   mapper: mapper)
        additionalInputErrors[uid] = nil
        let box = UncheckedSendableBox(session)
        sessionQueue.async { box.value.startRunning() }
        audioInputLog.info("Additional mic capture started: \(device.localizedName, privacy: .public)")
    }

    /// A05: a device's hardware input channel count — the maximum channel
    /// count across its audio formats (a stereo USB mic reads 2, an 8-in
    /// interface 8). Drives whether the channel-mapping UI has options.
    static func inputChannelCount(of device: AVCaptureDevice) -> Int {
        let channels = device.formats.compactMap { format -> Int? in
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                format.formatDescription) else { return nil }
            return Int(asbd.pointee.mChannelsPerFrame)
        }
        return max(1, channels.max() ?? 1)
    }

    // MARK: - C10 hot-plug entry points (driven by the DeviceMonitor)

    /// The DeviceMonitor saw an audio input connect. Re-enumerates, recovers
    /// the default mic if its exact device returned, and restarts any enabled
    /// additional device that was missing.
    func noteAudioDeviceConnected() {
        handleDeviceChange()
    }

    /// The DeviceMonitor saw an audio input disconnect. Only the affected
    /// channel's capture stops; every other input keeps running.
    func noteAudioDeviceDisconnected() {
        handleDeviceChange()
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
                errorMessage = "Cannot capture audio from \(device.localizedName)."
                audioInputLog.error("Cannot add audio input for \(device.localizedName, privacy: .public)")
                session.commitConfiguration()
                return
            }
            session.addInput(input)
        } catch {
            errorMessage = "Audio input failed: \(error.localizedDescription)"
            audioInputLog.error("Audio input failed: \(error.localizedDescription, privacy: .public)")
            session.commitConfiguration()
            return
        }

        let output = AVCaptureAudioDataOutput()
        let offMain = onMicSampleOffMain
        let shim = AudioCaptureShim { [weak self] sample, rawLevel in
            offMain?(sample.value)
            Task { @MainActor in
                guard let self else { return }
                self.onMicSample?(sample.value)
                if let rawLevel { self.publishLevel(rawLevel) }
            }
        }
        output.setSampleBufferDelegate(shim, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            errorMessage = "Cannot capture audio from \(device.localizedName)."
            audioInputLog.error("Cannot add audio data output")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        outputShim = shim
        activeDevice = device
        errorMessage = nil

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
            // C10 (issue #79): the live input was unplugged. Stop cleanly and
            // surface it through the existing per-source error surface —
            // never silently substitute another input. Capture resumes only
            // if the SAME device returns (below); choosing a different input
            // in Settings is the explicit relink path.
            errorMessage = "Microphone \"\(activeDevice.localizedName)\" was disconnected. Reconnect it, or choose another input in Settings."
            audioInputLog.error("Active audio input disconnected: \(activeDevice.localizedName, privacy: .public)")
            let session = self.session
            self.session = nil
            outputShim = nil
            self.activeDevice = nil
            if let session {
                let box = UncheckedSendableBox(session)
                sessionQueue.async { box.value.stopRunning() }
            }
            level = 0
            lastLevelPublishAt = 0
            isAwaitingDeviceReturn = true
        } else if isAwaitingDeviceReturn, session == nil,
           let uid = lastRequestedDeviceUID,
           let device = devices.first(where: { $0.uniqueID == uid }) {
            // Hot-plug recovery: the exact input that was in use is back.
            audioInputLog.info("Audio input returned, resuming: \(device.localizedName, privacy: .public)")
            start(device: device)
        }
        // A05: reconcile the additional devices against the new availability
        // (a returned device restarts; an unplugged one reports missing).
        reconcileAdditionalCaptures()
    }
}

/// A05: one additional input device's live capture state.
private struct AdditionalMicCapture {
    let session: AVCaptureSession
    /// Retained: `AVCaptureAudioDataOutput` holds its delegate weakly.
    let shim: AdditionalAudioCaptureShim
    let mapper: AudioDeviceChannelMapper
}

/// Transfers non-Sendable callback values (CMSampleBuffer, AVCaptureSession)
/// across the MainActor hop / session queue without actor-assuming thunks.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// A05: receives one ADDITIONAL device's `AVCaptureAudioDataOutput` buffers
/// on its serial sample queue and forwards them (through the channel mapper,
/// applied by the caller's closure) off-main. No metering here — the mix
/// engine meters the channel itself.
private final class AdditionalAudioCaptureShim: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
                                                @unchecked Sendable {
    private let handler: @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void

    init(handler: @escaping @Sendable (UncheckedSendableBox<CMSampleBuffer>) -> Void) {
        self.handler = handler
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        handler(UncheckedSendableBox(sampleBuffer))
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
