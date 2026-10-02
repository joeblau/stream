import AppKit
import CoreMedia
import ScreenCaptureKit

/// A12 qualification seam only. Production helper selection stays disabled. This capture is
/// requests the helper's exact application + PID; media ownership still needs measured proof.
/// Never connect these unqualified samples to a product mixer. There is no system/global branch.
@MainActor final class BrowserWidgetAudioCapture {
    enum CaptureError: Error { case permissionUnavailable, helperMissing, ambiguousHelper, displayMissing, windowMissing, holdbackUnavailable }
    enum FilterStyle: String, Codable, Sendable { case application, independentWindow }
    struct FilterIdentity: Codable, Sendable { var style: FilterStyle; var helperPID: Int32; var bundleID: String; var windowID: UInt32? }
    let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
    /// Any concurrent system-mix source MUST exclude this helper before a product route is enabled.
    let requiredSystemAudioExclusions: Set<String> = [BrowserWidgetAudioIdentity.helperBundleID]
    private(set) var isCapturing = false
    private(set) var failure: String?
    private(set) var requestedFilterIdentity: FilterIdentity?
    private var stream: SCStream?
    private var output: BrowserWidgetAudioOutput?
    private var activeGeneration: UUID?
    private let mixer: AudioMixEngine?
    private var holdbackToken: UUID?
    /// Measured local SCK transport can exceed 40 ms; this is an explicit opt-in 80 ms lease,
    /// preserving host PTS on every bus. It is not a per-widget A/V sync qualification.
    static let qualificationHoldbackMilliseconds = 80.0
    private let inlet: BrowserWidgetPCMInlet
    private let sampleQueue = DispatchQueue(label: "com.joeblau.StreamMac.browser-audio.capture", qos: .userInitiated)

    init(mixer: AudioMixEngine? = nil, sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.mixer = mixer; inlet = BrowserWidgetPCMInlet(sink: sink)
    }

    convenience init(mixer: AudioMixEngine) {
        let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        self.init(mixer: mixer) { sample in mixer.enqueue(channel, sample) }
    }

    /// The caller must own the launched helper, and keep it alive until `stop()` completes.
    /// Does not request permission: a missing existing Screen Recording grant fails closed.
    func startForQualification(helperPID: Int32, style: FilterStyle = .application) async throws {
        await stop()
        failure = nil
        guard CGSessionCopyCurrentDictionary() != nil, CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionUnavailable }
        guard let running = NSRunningApplication(processIdentifier: helperPID),
              !running.isTerminated, running.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID else { throw CaptureError.helperMissing }
        let content = try await SCShareableContent.current
        let matches = content.applications.filter {
            $0.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID && $0.processID == helperPID
        }
        guard matches.count == 1 else { throw matches.isEmpty ? CaptureError.helperMissing : CaptureError.ambiguousHelper }
        guard let display = content.displays.first else { throw CaptureError.displayMissing }
        let filter: SCContentFilter
        switch style {
        case .application:
            filter = SCContentFilter(display: display, including: matches, exceptingWindows: [])
            if #available(macOS 15.2, *) {
                guard filter.includedApplications.count == 1,
                      filter.includedApplications[0].processID == helperPID,
                      filter.includedApplications[0].bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID else { throw CaptureError.ambiguousHelper }
            }
            requestedFilterIdentity = FilterIdentity(style: style, helperPID: helperPID, bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        case .independentWindow:
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == helperPID && $0.owningApplication?.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID }) else { throw CaptureError.windowMissing }
            filter = SCContentFilter(desktopIndependentWindow: window)
            requestedFilterIdentity = FilterIdentity(style: style, helperPID: helperPID, bundleID: BrowserWidgetAudioIdentity.helperBundleID, windowID: window.windowID)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false; configuration.queueDepth = 4
        configuration.capturesAudio = true; configuration.sampleRate = 48_000; configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        let generation = inlet.begin()
        activeGeneration = generation
        if let mixer {
            let token = UUID()
            guard await mixer.reserveCaptureHoldback(token: token, milliseconds: Self.qualificationHoldbackMilliseconds) else {
                await stop(); throw CaptureError.holdbackUnavailable
            }
            holdbackToken = token
        }
        let output = BrowserWidgetAudioOutput(inlet: inlet, generation: generation) { [weak self] in
            Task { @MainActor in
                guard let self, self.activeGeneration == generation else { return }
                self.failure = "helper_audio_capture_stopped"
                await self.stop()
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            self.output = output; self.stream = stream
            try await stream.startCapture()
            isCapturing = true
        } catch {
            failure = "helper_audio_capture_start_failed"
            await stop()
            throw error
        }
    }

    func stop() async {
        let old = stream
        stream = nil; output = nil; activeGeneration = nil; isCapturing = false
        await inlet.stop()
        try? await old?.stopCapture()
        if let token = holdbackToken { holdbackToken = nil; await mixer?.releaseCaptureHoldback(token) }
    }
    func statistics() -> BrowserWidgetPCMInlet.Statistics { inlet.statistics() }
}

/// Retains at most 200 ms / 256 KiB of PCM and drains off the SCStream queue. Shed is local;
/// refresh/stop invalidates the generation and waits for already accepted sink calls to finish.
/// Existing mixer conversion preserves original host PTS and routes program/monitor/ISO independently.
final class BrowserWidgetPCMInlet: @unchecked Sendable {
    struct Statistics: Codable, Sendable {
        var received = 0, delivered = 0, dropped = 0, rejected = 0
        var maximumPendingFrames = 0, pendingFrames = 0
        var maximumPendingBytes = 0, discardedOnStop = 0
        var firstInputSampleRate: Double?
        var firstInputChannels: UInt32?
        var firstInputFrames: Int?
        var firstInputBytes: Int?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.joeblau.StreamMac.browser-audio.inlet", qos: .userInitiated)
    private let sink: @Sendable (CMSampleBuffer) -> Void
    private var generation = UUID()
    private var enabled = false, draining = false
    private struct Pending { var sample: CMSampleBuffer; var frames: Int; var bytes: Int }
    private var pending: [Pending] = []
    private var pendingBytes = 0
    private var stats = Statistics()
    private var lastPTS: CMTime = .invalid
    init(sink: @escaping @Sendable (CMSampleBuffer) -> Void) { self.sink = sink }
    func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); enabled = true; stats = Statistics(); lastPTS = .invalid
        return generation
    }
    func post(_ sample: CMSampleBuffer, generation expected: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, expected == generation else { stats.rejected += 1; return }
        // SCStream LPCM uses constant-frame ASBD sizing and may leave sample-size entries empty.
        // The retained block length is the actual bounded storage, unlike totalSampleSize == 0.
        let frames = sample.numSamples, bytes = sample.dataBuffer.map(CMBlockBufferGetDataLength) ?? sample.totalSampleSize
        let pts = sample.presentationTimeStamp
        if stats.firstInputFrames == nil {
            stats.firstInputFrames = frames; stats.firstInputBytes = bytes
            if let format = sample.formatDescription,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                stats.firstInputSampleRate = asbd.mSampleRate; stats.firstInputChannels = asbd.mChannelsPerFrame
            }
        }
        guard sample.isValid, sample.dataReadiness == .ready,
              let format = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48_000,
              asbd.mChannelsPerFrame == 2, frames > 0, frames <= 4_096,
              bytes > 0, bytes <= 65_536, pts.isNumeric,
              !lastPTS.isNumeric || CMTimeCompare(pts, lastPTS) > 0 else { stats.rejected += 1; return }
        lastPTS = pts; stats.received += 1
        while !pending.isEmpty && (pending.count >= 8 || stats.pendingFrames + frames > 9_600 || pendingBytes + bytes > 256 * 1_024) {
            let removed = pending.removeFirst()
            stats.pendingFrames -= removed.frames; pendingBytes -= removed.bytes; stats.dropped += 1
        }
        pending.append(Pending(sample: sample, frames: frames, bytes: bytes)); stats.pendingFrames += frames; pendingBytes += bytes
        stats.maximumPendingFrames = max(stats.maximumPendingFrames, stats.pendingFrames)
        stats.maximumPendingBytes = max(stats.maximumPendingBytes, pendingBytes)
        guard !draining else { return }
        draining = true
        queue.async { [self] in drain() }
    }
    func stop() async {
        lock.withLock {
            enabled = false; generation = UUID()
            stats.dropped += pending.count; stats.discardedOnStop += pending.count
            pending.removeAll(); pendingBytes = 0; stats.pendingFrames = 0
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func statistics() -> Statistics { lock.lock(); defer { lock.unlock() }; return stats }
    private func drain() {
        while true {
            lock.lock()
            guard enabled, !pending.isEmpty else { draining = false; lock.unlock(); return }
            let next = pending.removeFirst()
            stats.pendingFrames -= next.frames; pendingBytes -= next.bytes
            stats.delivered += 1
            lock.unlock()
            sink(next.sample)
        }
    }
}

private final class BrowserWidgetAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let inlet: BrowserWidgetPCMInlet
    let generation: UUID
    let onStopped: @Sendable () -> Void
    init(inlet: BrowserWidgetPCMInlet, generation: UUID, onStopped: @escaping @Sendable () -> Void) {
        self.inlet = inlet; self.generation = generation; self.onStopped = onStopped
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { inlet.post(sampleBuffer, generation: generation) }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { onStopped() }
}
