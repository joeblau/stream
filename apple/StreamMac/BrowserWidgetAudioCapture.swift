import AppKit
import CoreMedia
import ScreenCaptureKit

@MainActor protocol BrowserWidgetAudioDriver: AnyObject {
    var isCapturing: Bool { get }
    var requiresScreenCaptureAccess: Bool { get }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func start(helperPID: Int32) async throws
    func invalidateInput()
    func stop() async
}

/// The external SCK operation boundary. The production implementation owns
/// the real stream/output; capture-free fixtures hold only these async edges.
@MainActor protocol BrowserWidgetAudioProducer: AnyObject, Sendable {
    func start() async throws
    func stop() async
}

/// A12 qualification seam only. Production helper selection stays disabled. This capture
/// requests the helper's exact application + PID; media ownership still needs measured proof.
/// Never connect these unqualified samples to a product mixer. There is no system/global branch.
@MainActor final class BrowserWidgetAudioCapture: BrowserWidgetAudioDriver {
    enum CaptureError: Error { case permissionUnavailable, helperMissing, ambiguousHelper, displayMissing, windowMissing, holdbackUnavailable }
    enum FilterStyle: String, Codable, Sendable { case application, independentWindow }
    struct FilterIdentity: Codable, Sendable { var style: FilterStyle; var helperPID: Int32; var bundleID: String; var windowID: UInt32? }
    let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
    /// Any concurrent system-mix source MUST exclude this helper before a product route is enabled.
    let requiredSystemAudioExclusions: Set<String> = [BrowserWidgetAudioIdentity.helperBundleID]
    private(set) var isCapturing = false
    var requiresScreenCaptureAccess: Bool { validationPreparation == nil }
    private(set) var failure: String?
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var requestedFilterIdentity: FilterIdentity?
    struct PreparedCapture: Sendable {
        var producer: any BrowserWidgetAudioProducer
        var identity: FilterIdentity
    }
    typealias Preparation = @MainActor (Int32, FilterStyle, BrowserWidgetPCMInlet, UUID) async throws -> PreparedCapture
    private let validationPreparation: Preparation?
    /// Intent is established before any await, including retiring a previous run.
    private var operation = UUID()
    @MainActor private final class Run {
        let id = UUID()
        let inlet: BrowserWidgetPCMInlet
        let generation: UUID
        var producer: (any BrowserWidgetAudioProducer)?
        var preparation: Task<PreparedCapture, Error>?
        var starting: Task<Void, Error>?
        var reservation: (token: UUID, task: Task<Bool, Never>)?
        var retirement: Task<Void, Never>?
        init(sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
            inlet = BrowserWidgetPCMInlet(sink: sink); generation = inlet.begin()
        }
    }
    private var active: Run?
    private var lastInlet: BrowserWidgetPCMInlet?
    private var retirements: [UUID: Task<Void, Never>] = [:]
    private let mixer: AudioMixEngine?
    /// Measured local SCK transport can exceed 40 ms; this is an explicit opt-in 80 ms lease,
    /// preserving host PTS on every bus. It is not a per-widget A/V sync qualification.
    static let qualificationHoldbackMilliseconds = 80.0
    private let sink: @Sendable (CMSampleBuffer) -> Void
    private let sampleQueue = DispatchQueue(label: "com.joeblau.StreamMac.browser-audio.capture", qos: .userInitiated)

    init(mixer: AudioMixEngine? = nil, sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.mixer = mixer; self.sink = sink; validationPreparation = nil
    }
    #if STREAM_NATIVE_VALIDATION
    init(mixer: AudioMixEngine, validationPreparation: @escaping Preparation,
         sink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.mixer = mixer; self.sink = sink; self.validationPreparation = validationPreparation
    }
    #endif

    convenience init(mixer: AudioMixEngine) {
        let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        self.init(mixer: mixer) { sample in mixer.enqueue(channel, sample) }
    }

    /// The caller must own the launched helper, and keep it alive until `stop()` completes.
    /// Does not request permission: a missing existing Screen Recording grant fails closed.
    func startForQualification(helperPID: Int32, style: FilterStyle = .application) async throws {
        let request = UUID()
        operation = request
        let old = detachActive()
        await retire(old)
        guard operation == request, !Task.isCancelled else { throw CancellationError() }
        failure = nil
        let run = Run(sink: sink)
        active = run; lastInlet = run.inlet
        let preparation = Task { @MainActor in
            guard owns(run, request: request), !Task.isCancelled else { throw CancellationError() }
            if let validationPreparation {
                return try await validationPreparation(helperPID, style, run.inlet, run.generation)
            }
            return try await Self.prepareScreenCapture(helperPID: helperPID, style: style,
                inlet: run.inlet, generation: run.generation, sampleQueue: sampleQueue) { [weak self] in
                Task { @MainActor in
                    guard let self, self.owns(run, request: request) else { return }
                    self.failure = "helper_audio_capture_stopped"
                    let stopped = self.detachActive()
                    await self.retire(stopped)
                    guard self.operation == request else { return }
                    self.onFailure?("helper_audio_capture_stopped")
                }
            }
        }
        run.preparation = preparation
        do {
            let prepared = try await preparation.value
            guard owns(run, request: request), !Task.isCancelled else { throw CancellationError() }
            run.producer = prepared.producer
            requestedFilterIdentity = prepared.identity
            if let mixer {
                let token = UUID()
                let reservation = Task {
                    guard owns(run, request: request), !Task.isCancelled else { return false }
                    return await mixer.reserveCaptureHoldback(token: token, milliseconds: Self.qualificationHoldbackMilliseconds)
                }
                run.reservation = (token, reservation)
                let reserved = await reservation.value
                guard owns(run, request: request), !Task.isCancelled else { throw CancellationError() }
                guard reserved else { throw CaptureError.holdbackUnavailable }
            }
            let starting = Task {
                guard owns(run, request: request), !Task.isCancelled else { throw CancellationError() }
                try await prepared.producer.start()
            }
            run.starting = starting
            try await starting.value
            guard owns(run, request: request), !Task.isCancelled else { throw CancellationError() }
            isCapturing = true
        } catch {
            if owns(run, request: request) {
                if !(error is CancellationError) { failure = "helper_audio_capture_start_failed" }
                _ = detachActive()
            }
            // This waits producer-only tasks, never the current caller's catch.
            await retire(run)
            throw error
        }
    }

    private func owns(_ run: Run, request: UUID) -> Bool {
        operation == request && active === run
    }
    /// All authority and input revocation precedes opaque async producer cleanup.
    private func detachActive() -> Run? {
        let old = active
        active = nil; isCapturing = false
        old?.inlet.invalidate()
        return old
    }
    private func retire(_ run: Run?) async {
        guard let run else { return }
        if let retirement = run.retirement { await retirement.value; return }
        run.inlet.invalidate()
        let producer = run.producer, preparation = run.preparation, starting = run.starting
        let reservation = run.reservation, mixer = mixer
        run.producer = nil; run.preparation = nil; run.starting = nil; run.reservation = nil
        let task = Task {
            await run.inlet.waitUntilDrained()
            // A discovery already in flight may return an allocated stream after Stop.
            // Waiting this exact task also keeps the helper alive through final cleanup.
            let prepared = await preparation?.result
            let ownedProducer: (any BrowserWidgetAudioProducer)?
            if let producer { ownedProducer = producer }
            else if case .success(let value) = prepared { ownedProducer = value.producer }
            else { ownedProducer = nil }
            await ownedProducer?.stop()
            if let starting {
                _ = await starting.result
                // stopCapture may complete before pending startCapture unwinds.
                await ownedProducer?.stop()
            }
            if let reservation, await reservation.task.value {
                await mixer?.releaseCaptureHoldback(reservation.token)
            }
        }
        run.retirement = task; retirements[run.id] = task
        await task.value
        retirements[run.id] = nil
    }

    private static func prepareScreenCapture(helperPID: Int32, style: FilterStyle, inlet: BrowserWidgetPCMInlet,
                                             generation: UUID, sampleQueue: DispatchQueue, onStopped: @escaping @Sendable () -> Void) async throws -> PreparedCapture {
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
        let identity: FilterIdentity
        switch style {
        case .application:
            filter = SCContentFilter(display: display, including: matches, exceptingWindows: [])
            if #available(macOS 15.2, *) {
                guard filter.includedApplications.count == 1,
                      filter.includedApplications[0].processID == helperPID,
                      filter.includedApplications[0].bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID else { throw CaptureError.ambiguousHelper }
            }
            identity = FilterIdentity(style: style, helperPID: helperPID, bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        case .independentWindow:
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == helperPID && $0.owningApplication?.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID }) else { throw CaptureError.windowMissing }
            filter = SCContentFilter(desktopIndependentWindow: window)
            identity = FilterIdentity(style: style, helperPID: helperPID, bundleID: BrowserWidgetAudioIdentity.helperBundleID, windowID: window.windowID)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false; configuration.queueDepth = 4
        configuration.capturesAudio = true; configuration.sampleRate = 48_000; configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        let output = BrowserWidgetAudioOutput(inlet: inlet, generation: generation, onStopped: onStopped)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        return PreparedCapture(producer: BrowserWidgetScreenAudioProducer(stream: stream, output: output), identity: identity)
    }

    func stop() async {
        operation = UUID()
        let old = detachActive()
        // Snapshot prior cleanup only: this Stop cannot acquire a future run's resources.
        let pending = Array(retirements.values)
        await retire(old)
        for task in pending { await task.value }
    }
    func start(helperPID: Int32) async throws { try await startForQualification(helperPID: helperPID) }
    func invalidateInput() { active?.inlet.invalidate() }
    func statistics() -> BrowserWidgetPCMInlet.Statistics { lastInlet?.statistics() ?? .init() }

}

@MainActor private final class BrowserWidgetScreenAudioProducer: BrowserWidgetAudioProducer {
    private let stream: SCStream
    private let output: BrowserWidgetAudioOutput
    init(stream: SCStream, output: BrowserWidgetAudioOutput) { self.stream = stream; self.output = output }
    func start() async throws { try await stream.startCapture() }
    func stop() async { try? await stream.stopCapture() }
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
    func invalidate() {
        lock.withLock {
            enabled = false; generation = UUID()
            stats.dropped += pending.count; stats.discardedOnStop += pending.count
            pending.removeAll(); pendingBytes = 0; stats.pendingFrames = 0
        }
    }
    func stop() async {
        invalidate()
        await waitUntilDrained()
    }
    func waitUntilDrained() async {
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
