import AppKit
import CoreMedia
import CoreVideo

/// Internal transport seam lets owned fixtures reject a command without launching
/// a helper or touching capture permissions. Product sessions use the PID-checked
/// connection below.
protocol BrowserWidgetHelperTransport: AnyObject {
    var pid: Int32 { get }
    @MainActor func send(_ value: BrowserWidgetAudioCommand) throws
    @MainActor func close()
    @MainActor var hasTerminated: Bool { get }
}

extension BrowserWidgetHelperTransport { @MainActor var hasTerminated: Bool { false } }

/// Explicit qualification backend. No app startup or preference enables this session. One
/// LaunchServices application owns each page's pixels, interaction, and shared audio identity.
/// Callers must retain the session until `waitUntilStopped()` completes and apply its required
/// system-audio exclusions before any future production opt-in.
@MainActor final class BrowserWidgetHelperSession {
    enum SessionError: Error { case widgetLimit, unavailable }
    struct Callbacks {
        var state: @MainActor (BrowserOverlayLoadState) -> Void
        var frame: @MainActor (CVPixelBuffer, BrowserWidgetVisualHeader) -> Void
        var snapshotFailed: @MainActor () -> Void
        var audioState: @MainActor (String?) -> Void = { _ in }
    }
    struct Statistics: Codable, Sendable {
        var receivedFrames = 0, rejectedFrames = 0, shedRequests = 0
        var maximumReceivedFrameBytes = 0
        var maximumSnapshotLatencyMilliseconds = 0.0
    }
    private struct Demand { var generation: UUID; var command: BrowserWidgetAudioCommand; var callbacks: Callbacks }
    private struct PendingMedia { var lease: BrowserWidgetPageLease; var suspended: Bool; var retiring = false; var continuation: CheckedContinuation<Bool, Never> }
    private struct PendingFrame { var widget: UUID; var generation: UUID; var request: UUID; var timeout: Timer }
    let requiredSystemAudioExclusions = Set([BrowserWidgetAudioIdentity.helperBundleID])
    let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
    private(set) var failure: String?
    private(set) var statistics = Statistics()
    private(set) var lastFrameHeader: BrowserWidgetVisualHeader?
    var demandCount: Int { demands.count }
    /// Qualification runtime owners can include this identity when reconciling mixer channels.
    /// Only actual qualification demand advertises it; saved web keys confer no capability.
    var demandedAudioChannels: Set<AudioChannelID> { demands.isEmpty ? [] : [channel] }
    func ownsMixer(_ candidate: AudioMixEngine) -> Bool { mixer === candidate }
    var helperPID: Int32? { connection?.pid }
    var audioIsCapturing: Bool { audio.isCapturing }
    private let applicationURL: URL
    private let ipcPolicy: BrowserWidgetAudioSocket.Policy
    private let acceptsInjectedReplies: Bool
    private let audio: any BrowserWidgetAudioDriver
    private let mixer: AudioMixEngine?
    private var connection: (any BrowserWidgetHelperTransport)?
    private var launchTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownID = UUID()
    private var loadClaims: [UUID: UUID] = [:]
    private let localSession = UUID()
    private var localPages: [BrowserWidgetPageLease: BrowserWidgetLocalContent.Snapshot] = [:]
    private var localStaging = 0
    #if STREAM_NATIVE_VALIDATION
    var validationLocalContainer: URL?
    #endif
    private var audioTask: Task<Void, Never>?
    private var audioRevision = UUID()
    private var requestedProgramLeases: Set<BrowserWidgetPageLease> = []
    private var captureExclusionPermit: BrowserCaptureExclusionPermit?
    private var loadedLeases: Set<BrowserWidgetPageLease> = []
    private var suspendedLeases: Set<BrowserWidgetPageLease> = []
    private(set) var audibleLeases: Set<BrowserWidgetPageLease> = []
    private(set) var audioUnavailableReason: String?
    /// Runtime owner seeds saved mixer intent while the final route gate is closed.
    /// A missing preparation leaves the route unavailable; this callback never starts capture.
    struct MixerPreparation { var isCurrent: @MainActor () -> Bool }
    var prepareMixerForAudio: (@MainActor () async -> MixerPreparation?)? {
        didSet {
            // Registration can follow visual demand; withdrawal revokes an
            // already audible route synchronously. Replacing the same owner's
            // live preparer during reconciliation does not restart its audio.
            guard !demands.isEmpty, oldValue == nil || prepareMixerForAudio == nil else { return }
            closeAudioBoundary(); reconcileAudio()
        }
    }
    private var captureConflict: String?
    private var pendingMedia: [UUID: PendingMedia] = [:]
    private var retiredLeases: Set<BrowserWidgetPageLease> = []
    private var installedLeases: Set<BrowserWidgetPageLease> = []
    private var retirementWaiters: [BrowserWidgetPageLease: [CheckedContinuation<Bool, Never>]] = [:]
    private var epoch = UUID()
    private var demands: [UUID: Demand] = [:]
    private var pools: [UUID: CVPixelBufferPool] = [:]
    private var pendingFrame: PendingFrame?
    private var evaluations: [UUID: CheckedContinuation<String?, Never>] = [:]

    init(applicationURL: URL, mixer: AudioMixEngine? = nil,
         ipcPolicy: BrowserWidgetAudioSocket.Policy = .production,
         transportForQualification: (any BrowserWidgetHelperTransport)? = nil,
         audioSink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.applicationURL = applicationURL; self.mixer = mixer; self.ipcPolicy = ipcPolicy
        self.connection = transportForQualification
        acceptsInjectedReplies = transportForQualification != nil
        audio = BrowserWidgetAudioCapture(mixer: mixer, sink: audioSink)
        audio.onFailure = { [weak self] category in self?.failSession(category) }
        mixer?.setCaptureRouteAllowed(channel, allowed: false)
    }
    #if STREAM_NATIVE_VALIDATION
    init(applicationURL: URL, mixer: AudioMixEngine, validationAudioDriver: any BrowserWidgetAudioDriver,
         ipcPolicy: BrowserWidgetAudioSocket.Policy = .production,
         transportForQualification: (any BrowserWidgetHelperTransport)? = nil) {
        self.applicationURL = applicationURL; self.mixer = mixer; self.ipcPolicy = ipcPolicy; audio = validationAudioDriver
        connection = transportForQualification; acceptsInjectedReplies = transportForQualification != nil
        audio.onFailure = { [weak self] category in self?.failSession(category) }
        mixer.setCaptureRouteAllowed(channel, allowed: false)
    }
    func validationReceive(_ reply: BrowserWidgetAudioReply) {
        guard acceptsInjectedReplies else { return }
        receive(reply, epoch: epoch)
    }
    #endif
    convenience init(applicationURL: URL, mixer: AudioMixEngine, ipcPolicy: BrowserWidgetAudioSocket.Policy = .production) {
        let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        self.init(applicationURL: applicationURL, mixer: mixer, ipcPolicy: ipcPolicy) { mixer.enqueue(channel, $0) }
    }
    /// Packaged helper lookup has no launch or permission side effects.
    static func packagedHelperURL(bundle: Bundle = .main) -> URL? {
        let candidate = bundle.bundleURL.appendingPathComponent("Contents/Helpers/StreamBrowserAudioHelper.app")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func loadForQualification(id: UUID, generation: UUID, html: String? = nil, url: URL? = nil, localSource: URL? = nil,
                              options: BrowserWidgetPageOptions, callbacks: Callbacks) async throws {
        var quietOptions = options
        quietOptions.mediaStartsSuspended = true
        var command = BrowserWidgetAudioCommand(action: .load, widgetID: id, html: html, url: url,
                                               options: quietOptions, generation: generation)
        guard localSource == nil || (html == nil && url == nil) else { throw SessionError.unavailable }
        if localSource == nil { try command.validate() }
        guard loadClaims[id] != nil || loadClaims.count < BrowserWidgetAudioCommand.maximumWidgets else { throw SessionError.widgetLimit }
        let claim = UUID()
        loadClaims[id] = claim
        defer { if loadClaims[id] == claim { loadClaims[id] = nil } }
        if demands[id] != nil { retireDemand(id) }
        for lease in retiredLeases.filter({ $0.widgetID == id }) {
            let retired = await withCheckedContinuation { continuation in
                retirementWaiters[lease, default: []].append(continuation)
            }
            guard retired else { throw SessionError.unavailable }
        }
        while let shutdownTask {
            let retiringShutdown = shutdownID
            await shutdownTask.value
            guard loadClaims[id] == claim else { throw CancellationError() }
            if shutdownID == retiringShutdown { self.shutdownTask = nil }
        }
        try Task.checkCancellation()
        guard loadClaims[id] == claim else { throw CancellationError() }
        guard demands.count < BrowserWidgetAudioCommand.maximumWidgets else { throw SessionError.widgetLimit }
        var staged: BrowserWidgetLocalContent.Snapshot?
        if let localSource {
            guard localStaging + localPages.count + BrowserWidgetLocalRetirement.retainedCount < BrowserWidgetAudioCommand.maximumWidgets * 2 else {
                throw SessionError.widgetLimit
            }
            localStaging += 1
            defer { localStaging -= 1 }
            let container: URL
            #if STREAM_NATIVE_VALIDATION
            container = try validationLocalContainer ?? BrowserWidgetLocalContent.container()
            #else
            container = try BrowserWidgetLocalContent.container()
            #endif
            let session = localSession
            let copy = Task.detached {
                try BrowserWidgetLocalContent.stage(source: localSource, container: container,
                    session: session, widget: id, generation: generation)
            }
            staged = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
            guard loadClaims[id] == claim, !Task.isCancelled else { try? staged?.retire(); throw CancellationError() }
            command.localPage = staged?.page
            do { try command.validate() } catch { try? staged?.retire(); throw error }
        }
        // A sibling can start shutdown while the off-main copy is running.
        // Re-enter the same serialized shutdown barrier before installing it.
        while let shutdownTask {
            let retiringShutdown = shutdownID
            await shutdownTask.value
            guard loadClaims[id] == claim, !Task.isCancelled else { try? staged?.retire(); throw CancellationError() }
            if shutdownID == retiringShutdown { self.shutdownTask = nil }
        }
        guard demands.count < BrowserWidgetAudioCommand.maximumWidgets else { try? staged?.retire(); throw SessionError.widgetLimit }
        failure = nil
        loadedLeases = loadedLeases.filter { $0.widgetID != id }
        suspendedLeases = suspendedLeases.filter { $0.widgetID != id }
        cancelMedia(for: id)
        closeAudioBoundary()
        demands[id] = Demand(generation: generation, command: command, callbacks: callbacks)
        if let staged { localPages[.init(widgetID: id, generation: generation)] = staged }
        pools[id] = nil
        cancelSnapshot(for: id)
        callbacks.state(.loading)
        do {
            try await ensureLaunched()
            try Task.checkCancellation()
            guard loadClaims[id] == claim, demands[id]?.generation == generation else { throw CancellationError() }
            try connection?.send(command)
            installedLeases.insert(.init(widgetID: id, generation: generation))
        } catch {
            guard loadClaims[id] == claim, demands[id]?.generation == generation else { throw error }
            callbacks.state(.failed("The browser helper couldn't start. Independent audio remains unavailable."))
            release(id)
            throw error
        }
    }

    /// Last demand owns shutdown; a new demand waits for capture/socket/holdback cleanup first.
    func release(_ id: UUID) {
        loadClaims[id] = nil
        retireDemand(id)
    }
    private func retireDemand(_ id: UUID) {
        guard let demand = demands.removeValue(forKey: id) else { return }
        let lease = BrowserWidgetPageLease(widgetID: id, generation: demand.generation)
        if installedLeases.remove(lease) != nil { retiredLeases.insert(lease) }
        else if let page = localPages.removeValue(forKey: lease) {
            BrowserWidgetLocalRetirement.retain([page], until: { true })
        }
        loadedLeases = loadedLeases.filter { $0.widgetID != id }
        suspendedLeases = suspendedLeases.filter { $0.widgetID != id }
        cancelMedia(for: id)
        closeAudioBoundary()
        pools[id] = nil; cancelSnapshot(for: id)
        reconcileAudio()
    }
    func waitUntilStopped() async { await audioTask?.value; await shutdownTask?.value }

    @discardableResult func requestSnapshot(id: UUID, generation: UUID) -> Bool {
        guard demands[id]?.generation == generation, let connection else { return false }
        guard pendingFrame == nil else { statistics.shedRequests += 1; return false }
        let request = UUID()
        let timeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.pendingFrame?.request == request else { return }
                // A wedged transport cannot accumulate another request or retain a dead frame.
                self?.failSession("helper_frame_timeout")
            }
        }
        pendingFrame = PendingFrame(widget: id, generation: generation, request: request, timeout: timeout)
        do { try connection.send(.init(action: .snapshot, widgetID: id, requestID: request, generation: generation)); return true }
        catch { cancelSnapshot(for: id); failSession("helper_command_failed"); return false }
    }

    func sendInteraction(id: UUID, generation: UUID, input: BrowserWidgetInteraction) {
        guard demands[id]?.generation == generation, demands[id]?.command.options?.allowsInteraction == true else { return }
        do { try connection?.send(.init(action: .interact, widgetID: id, generation: generation, interaction: input)) }
        catch { failSession("helper_command_failed") }
    }
    func evaluate(id: UUID, generation: UUID, expression: String) async -> String? {
        guard demands[id]?.generation == generation, evaluations.count < 16, let connection else { return nil }
        let request = UUID()
        return await withCheckedContinuation { continuation in
            evaluations[request] = continuation
            do { try connection.send(.init(action: .evaluate, widgetID: id, requestID: request, generation: generation, expression: expression)) }
            catch { evaluations.removeValue(forKey: request)?.resume(returning: nil) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.evaluations.removeValue(forKey: request)?.resume(returning: nil)
            }
        }
    }
    func setSuspended(id: UUID, suspended: Bool) {
        guard let generation = demands[id]?.generation else { return }
        setSuspended(id: id, generation: generation, suspended: suspended)
    }
    func setSuspended(id: UUID, generation: UUID, suspended: Bool) {
        guard demands[id]?.generation == generation else { return }
        let lease = BrowserWidgetPageLease(widgetID: id, generation: generation)
        if suspended { suspendedLeases.insert(lease) } else { suspendedLeases.remove(lease) }
        closeAudioBoundary(); reconcileAudio()
    }

    /// Pixels may be demanded by Preview/standby/ISO. Only current Program leases may resume
    /// media. The shared application channel is never an independent authorization to play.
    func setProgramAudioDemand(_ leases: Set<BrowserWidgetPageLease>,
                               exclusions: BrowserCaptureExclusionPermit?, unavailableReason: String? = nil) {
        guard leases != requestedProgramLeases || exclusions?.id != captureExclusionPermit?.id ||
              unavailableReason != captureConflict else { return }
        requestedProgramLeases = leases; captureExclusionPermit = exclusions
        captureConflict = unavailableReason
        closeAudioBoundary(); reconcileAudio()
    }
    #if STREAM_NATIVE_VALIDATION
    /// Explicit no-broad-capture fixture boundary. Production must supply owner receipts.
    private var validationExclusions: (Set<String>, UUID)?
    func setProgramAudioDemand(_ leases: Set<BrowserWidgetPageLease>, applyingExclusions: Set<String>,
                               unavailableReason: String? = nil) {
        if validationExclusions?.0 != applyingExclusions { validationExclusions = (applyingExclusions, UUID()) }
        let permit: BrowserCaptureExclusionPermit? = applyingExclusions.isSuperset(of: requiredSystemAudioExclusions)
            ? .init(id: validationExclusions!.1, helperPID: helperPID ?? -1, isCurrent: { true }) : nil
        setProgramAudioDemand(leases, exclusions: permit, unavailableReason: unavailableReason)
    }
    #endif

    /// This synchronous boundary also fences an already-entered inlet callback. Draining and
    /// FX resets run in the serial worker, never while a UI callback waits on opaque plug-ins.
    private func closeAudioBoundary() {
        audioRevision = UUID(); audibleLeases = []
        mixer?.setCaptureRouteAllowed(channel, allowed: false)
        audio.invalidateInput()
        for (id, demand) in demands {
            try? connection?.send(.init(action: .suspend, widgetID: id, generation: demand.generation))
        }
    }
    private func reconcileAudio() {
        guard audioTask == nil, shutdownTask == nil else { return }
        audioTask = Task { [weak self] in
            guard let self else { return }
            var staleMixerPreparations = 0
            while !Task.isCancelled, !demands.isEmpty || !retiredLeases.isEmpty {
                let revision = audioRevision
                await audio.stop()
                await mixer?.resetCaptureRouteHistory(channel)
                guard !Task.isCancelled else { break }
                if revision != audioRevision { continue }
                var retirementFailed = false
                for lease in retiredLeases {
                    if await acknowledgeMedia(lease, suspended: true, retiring: true) {
                        retiredLeases.remove(lease)
                        if let page = localPages.removeValue(forKey: lease) {
                            BrowserWidgetLocalRetirement.retain([page], until: { true })
                        }
                        for waiter in retirementWaiters.removeValue(forKey: lease) ?? [] { waiter.resume(returning: true) }
                    } else { retirementFailed = true; break }
                }
                guard !retirementFailed else { failSession("helper_page_retirement_failed"); break }
                if revision != audioRevision { continue }
                let current = Set(demands.map { BrowserWidgetPageLease(widgetID: $0.key, generation: $0.value.generation) })
                var allSuspended = true
                for lease in current.intersection(loadedLeases) {
                    if !(await acknowledgeMedia(lease, suspended: true)) { allSuspended = false; break }
                    if revision != audioRevision || Task.isCancelled { break }
                }
                guard !Task.isCancelled else { break }
                if revision != audioRevision { continue }
                guard allSuspended else { failSession("helper_media_suspend_failed"); break }
                let target = current.intersection(requestedProgramLeases).intersection(loadedLeases)
                    .subtracting(suspendedLeases)
                let reason: String?
                if target.isEmpty { reason = "Independent browser audio is silent outside Program." }
                else if let captureConflict { reason = captureConflict }
                else if captureExclusionPermit?.allows(connection?.pid ?? -1) != true {
                    reason = "Independent browser audio is unavailable until other capture routes exclude its helper."
                } else if mixer == nil { reason = "Independent browser audio requires its owned mixer channel." }
                else if prepareMixerForAudio == nil { reason = "Independent browser audio requires current mixer preparation." }
                else { reason = nil }
                publishAudioState(reason ?? "Independent browser audio is preparing its Program route.")
                if reason != nil { break }
                guard let pid = connection?.pid else { break }
                guard captureExclusionPermit?.allows(pid) == true else { break }
                do { try await audio.start(helperPID: pid) }
                catch { if revision == audioRevision { failSession("helper_audio_unavailable") }; break }
                if revision != audioRevision { continue }
                guard captureExclusionPermit?.allows(pid) == true else { continue }
                var allResumed = true
                for lease in target {
                    guard revision == audioRevision, captureExclusionPermit?.allows(pid) == true else { break }
                    if !(await acknowledgeMedia(lease, suspended: false)) { allResumed = false; break }
                    if revision != audioRevision || Task.isCancelled { break }
                }
                guard !Task.isCancelled else { break }
                if revision != audioRevision { continue }
                guard captureExclusionPermit?.allows(pid) == true else { continue }
                guard allResumed, audio.isCapturing else { failSession("helper_media_resume_failed"); break }
                guard let prepareMixerForAudio else { continue }
                do {
                    let prepared = await prepareMixerForAudio()
                    guard revision == audioRevision, !Task.isCancelled else { continue }
                    guard let prepared else { failSession("helper_mixer_unavailable"); break }
                    // No await between this live settings check and final gate-open.
                    if !prepared.isCurrent() {
                        staleMixerPreparations += 1
                        if staleMixerPreparations >= 8 { failSession("helper_mixer_unavailable"); break }
                        continue
                    }
                }
                guard revision == audioRevision, !Task.isCancelled else { continue }
                guard captureExclusionPermit?.allows(pid) == true else { continue }
                audibleLeases = target
                mixer?.setCaptureRouteAllowed(channel, allowed: true)
                publishAudioState(nil)
                break
            }
            audioTask = nil
            if demands.isEmpty && retiredLeases.isEmpty { beginShutdown() }
        }
    }
    private func publishAudioState(_ reason: String?) {
        audioUnavailableReason = reason
        for demand in demands.values { demand.callbacks.audioState(reason) }
    }
    private func acknowledgeMedia(_ lease: BrowserWidgetPageLease, suspended: Bool, retiring: Bool = false) async -> Bool {
        let current = retiring ? retiredLeases.contains(lease) : demands[lease.widgetID]?.generation == lease.generation
        guard current, let connection,
              pendingMedia.count < BrowserWidgetAudioCommand.maximumWidgets * 2 else { return false }
        let request = UUID()
        return await withCheckedContinuation { continuation in
            pendingMedia[request] = PendingMedia(lease: lease, suspended: suspended, retiring: retiring, continuation: continuation)
            do { try connection.send(.init(action: retiring ? .stop : (suspended ? .suspend : .resume), widgetID: lease.widgetID,
                                           requestID: request, generation: lease.generation)) }
            catch { pendingMedia.removeValue(forKey: request)?.continuation.resume(returning: false) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.pendingMedia.removeValue(forKey: request)?.continuation.resume(returning: false)
            }
        }
    }
    private func cancelMedia(for id: UUID) {
        for request in pendingMedia.keys.filter({ pendingMedia[$0]?.lease.widgetID == id && pendingMedia[$0]?.retiring == false }) {
            pendingMedia.removeValue(forKey: request)?.continuation.resume(returning: false)
        }
    }

    private func ensureLaunched() async throws {
        if connection != nil { return }
        if let launchTask { try await launchTask.value; return }
        // Fail before loading an audible page; preflight never requests or modifies permission.
        guard CGSessionCopyCurrentDictionary() != nil,
              !audio.requiresScreenCaptureAccess || CGPreflightScreenCaptureAccess() else { throw SessionError.unavailable }
        let expected = epoch
        let task = Task {
            let connection = try await BrowserWidgetHelperConnection.launch(applicationURL: applicationURL, policy: ipcPolicy,
                onReply: { [weak self] in self?.receive($0, epoch: expected) },
                onFrame: { [weak self] in self?.receive($0, pixels: $1, epoch: expected) },
                onClosed: { [weak self] in if self?.epoch == expected { self?.failSession("helper_disconnected") } })
            guard !Task.isCancelled, expected == epoch, !demands.isEmpty else { connection.close(); throw SessionError.unavailable }
            self.connection = connection
        }
        launchTask = task
        do { try await task.value; launchTask = nil }
        catch { launchTask = nil; throw error }
    }
    private func receive(_ reply: BrowserWidgetAudioReply, epoch expected: UUID) {
        guard expected == epoch, reply.helperPID == connection?.pid else { return }
        if let request = reply.requestID {
            if let pending = pendingMedia[request] {
                let matches = reply.widgetID == pending.lease.widgetID && reply.generation == pending.lease.generation
                    && (pending.retiring ? retiredLeases.contains(pending.lease) : demands[pending.lease.widgetID]?.generation == pending.lease.generation)
                let success = matches && reply.state == (pending.retiring ? .stopped : (pending.suspended ? .suspended : .loaded))
                pendingMedia.removeValue(forKey: request)?.continuation.resume(returning: success)
                return
            }
            if reply.state == .evaluated || reply.state == .failed {
                evaluations.removeValue(forKey: request)?.resume(returning: reply.state == .evaluated ? reply.result : nil)
            }
            if reply.state == .failed, pendingFrame?.request == request {
                let id = pendingFrame!.widget; cancelSnapshot(for: id); demands[id]?.callbacks.snapshotFailed()
            }
            return
        }
        guard let id = reply.widgetID, let demand = demands[id], reply.generation == demand.generation else { return }
        switch reply.state {
        case .loaded:
            demand.callbacks.state(.ready)
            let lease = BrowserWidgetPageLease(widgetID: id, generation: demand.generation)
            if loadedLeases.insert(lease).inserted {
                closeAudioBoundary(); reconcileAudio()
            }
        case .failed:
            demand.callbacks.state(.failed("The browser helper page stopped. Reload the widget to retry."))
            release(id)
        default: break
        }
    }
    private func receive(_ header: BrowserWidgetVisualHeader, pixels: Data, epoch expected: UUID) {
        guard expected == epoch, let pendingFrame, pendingFrame.widget == header.widgetID,
              pendingFrame.generation == header.generation, pendingFrame.request == header.requestID,
              let demand = demands[header.widgetID], demand.generation == header.generation else {
            statistics.rejectedFrames += 1; return
        }
        cancelSnapshot(for: header.widgetID)
        guard let buffer = pixelBuffer(header: header, pixels: pixels) else { demand.callbacks.snapshotFailed(); return }
        statistics.receivedFrames += 1
        statistics.maximumReceivedFrameBytes = max(statistics.maximumReceivedFrameBytes, pixels.count)
        statistics.maximumSnapshotLatencyMilliseconds = max(statistics.maximumSnapshotLatencyMilliseconds,
            (header.completedHostSeconds - header.requestedHostSeconds) * 1_000)
        lastFrameHeader = header
        demand.callbacks.frame(buffer, header)
    }
    private func pixelBuffer(header: BrowserWidgetVisualHeader, pixels: Data) -> CVPixelBuffer? {
        if pools[header.widgetID] == nil {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: header.width, kCVPixelBufferHeightKey as String: header.height,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            pools[header.widgetID] = pool
        }
        guard let pool = pools[header.widgetID] else { return nil }
        var buffer: CVPixelBuffer?
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferGetWidth(buffer) == header.width, CVPixelBufferGetHeight(buffer) == header.height else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        pixels.withUnsafeBytes { bytes in
            for row in 0..<header.height {
                base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).copyMemory(
                    from: bytes.baseAddress!.advanced(by: row * header.width * 4), byteCount: header.width * 4)
            }
        }
        return buffer
    }
    private func cancelSnapshot(for id: UUID) {
        guard pendingFrame?.widget == id else { return }
        pendingFrame?.timeout.invalidate(); pendingFrame = nil
    }
    private func failSession(_ category: String) {
        guard failure == nil else { return }
        failure = category; loadClaims.removeAll()
        for demand in demands.values { demand.callbacks.state(.failed("The browser helper stopped. Independent audio remains unavailable.")) }
        demands.removeAll(); pools.removeAll(); beginShutdown()
    }
    private func beginShutdown() {
        guard shutdownTask == nil else { return }
        shutdownID = UUID()
        closeAudioBoundary()
        epoch = UUID()
        for pending in pendingMedia.values { pending.continuation.resume(returning: false) }; pendingMedia.removeAll()
        for waiters in retirementWaiters.values { for waiter in waiters { waiter.resume(returning: false) } }
        retirementWaiters.removeAll(); retiredLeases = []; installedLeases = []
        loadedLeases = []; suspendedLeases = []; requestedProgramLeases = []
        pendingFrame?.timeout.invalidate(); pendingFrame = nil
        for continuation in evaluations.values { continuation.resume(returning: nil) }; evaluations.removeAll()
        shutdownTask = Task { [self] in
            launchTask?.cancel(); try? await launchTask?.value; launchTask = nil
            let retiringConnection = connection
            let pages = Array(localPages.values); localPages.removeAll()
            try? retiringConnection?.send(.init(action: .close)); retiringConnection?.close(); connection = nil
            BrowserWidgetLocalRetirement.retain(pages, until: { retiringConnection == nil || retiringConnection?.hasTerminated == true })
            audioTask?.cancel(); await audioTask?.value; audioTask = nil
            await audio.stop(); await mixer?.resetCaptureRouteHistory(channel)
            await mixer?.removeChannel(channel)
        }
    }
}

/// Separate bounded command and frame connections keep visual readback off audio queues. Both
/// accepted peers must match the exact LaunchServices PID. Readers deliver at most one item to
/// MainActor at a time; socket closure wakes them, and command writes have a 256 KiB / 64-item cap.
private final class BrowserWidgetHelperConnection: BrowserWidgetHelperTransport, @unchecked Sendable {
    let pid: Int32
    private let application: NSRunningApplication
    private let command: FileHandle, frames: FileHandle
    private let listeners: [BrowserWidgetAudioSocket]
    private let lock = NSLock(), writer = DispatchQueue(label: "browser-helper.commands.write")
    private var closed = false, pendingBytes = 0, pendingCommands = 0
    private let onReply: @MainActor @Sendable (BrowserWidgetAudioReply) -> Void
    private let onFrame: @MainActor @Sendable (BrowserWidgetVisualHeader, Data) -> Void
    private let onClosed: @MainActor @Sendable () -> Void
    @MainActor private init(application: NSRunningApplication, command: FileHandle, frames: FileHandle,
                 listeners: [BrowserWidgetAudioSocket], onReply: @escaping @MainActor @Sendable (BrowserWidgetAudioReply) -> Void,
                 onFrame: @escaping @MainActor @Sendable (BrowserWidgetVisualHeader, Data) -> Void,
                 onClosed: @escaping @MainActor @Sendable () -> Void) {
        self.application = application; pid = application.processIdentifier
        self.command = command; self.frames = frames; self.listeners = listeners
        self.onReply = onReply; self.onFrame = onFrame; self.onClosed = onClosed
        var noSignal: Int32 = 1
        setsockopt(command.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }
    @MainActor static func launch(applicationURL: URL, policy: BrowserWidgetAudioSocket.Policy, onReply: @escaping @MainActor @Sendable (BrowserWidgetAudioReply) -> Void,
                       onFrame: @escaping @MainActor @Sendable (BrowserWidgetVisualHeader, Data) -> Void,
                       onClosed: @escaping @MainActor @Sendable () -> Void) async throws -> BrowserWidgetHelperConnection {
        let authority = try BrowserWidgetAudioSocket.Authority.host(helperURL: applicationURL, policy: policy)
        let commandListener = try BrowserWidgetAudioSocket(authority: authority), frameListener = try BrowserWidgetAudioSocket(authority: authority)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--ipc-mode", "production", "--host-pid", String(getpid()),
                            "--ipc-socket", commandListener.path, "--frame-socket", frameListener.path]
        #if STREAM_NATIVE_VALIDATION
        if case .prototypeForQualification = policy {
            guard let executable = Bundle.main.executableURL else { throw BrowserWidgetHelperSession.SessionError.unavailable }
            config.arguments = ["--ipc-mode", "prototype", "--host-pid", String(getpid()), "--host-executable", executable.path,
                                "--ipc-socket", commandListener.path, "--frame-socket", frameListener.path]
        }
        #endif
        config.activates = false; config.createsNewApplicationInstance = true; config.addsToRecentItems = false
        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: config)
        guard application.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID else { application.terminate(); throw BrowserWidgetHelperSession.SessionError.unavailable }
        do {
            let command = try await commandListener.accept(expectedPID: application.processIdentifier)
            let frames = try await frameListener.accept(expectedPID: application.processIdentifier)
            guard commandListener.principal == frameListener.principal else {
                try? command.close(); try? frames.close(); throw BrowserWidgetHelperSession.SessionError.unavailable
            }
            let connection = BrowserWidgetHelperConnection(application: application, command: command, frames: frames,
                listeners: [commandListener, frameListener], onReply: onReply, onFrame: onFrame, onClosed: onClosed)
            connection.startReaders(); return connection
        } catch { application.terminate(); throw error }
    }
    func send(_ value: BrowserWidgetAudioCommand) throws {
        let bytes = try value.encodedLine()
        let accepted = lock.withLock { () -> Bool in
            guard !closed, pendingCommands < 64, pendingBytes + bytes.count <= 256 * 1_024 else { return false }
            pendingCommands += 1; pendingBytes += bytes.count; return true
        }
        guard accepted else { throw BrowserWidgetHelperSession.SessionError.unavailable }
        writer.async { [self] in
            defer { lock.withLock { pendingCommands -= 1; pendingBytes -= bytes.count } }
            guard !lock.withLock({ closed }) else { return }
            // A command peer that stops reading cannot pin a writer thread forever.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(command.fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            do { try command.write(contentsOf: bytes) } catch { disconnected() }
        }
    }
    private func startReaders() {
        DispatchQueue(label: "browser-helper.replies.read").async { [self] in
            var bytes = Data(), chunk = [UInt8](repeating: 0, count: 4_096)
            while !lock.withLock({ closed }) {
                let count = Darwin.read(command.fileDescriptor, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                bytes.append(contentsOf: chunk.prefix(count))
                guard bytes.count <= BrowserWidgetAudioCommand.maximumLineBytes else { break }
                while let end = bytes.firstIndex(of: 10) {
                    let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
                    guard let reply = try? JSONDecoder().decode(BrowserWidgetAudioReply.self, from: line),
                          (reply.result?.utf8.count ?? 0) <= 4_096 else { disconnected(); return }
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { [self] in onReply(reply); done.signal() }; done.wait()
                }
            }
            disconnected()
        }
        DispatchQueue(label: "browser-helper.frames.read", qos: .userInitiated).async { [self] in
            do {
                while !lock.withLock({ closed }) {
                    let (header, pixels) = try BrowserWidgetVisualTransport.read(descriptor: frames.fileDescriptor)
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { [self] in onFrame(header, pixels); done.signal() }; done.wait()
                }
            } catch { disconnected() }
        }
    }
    private func disconnected() {
        let first = lock.withLock { () -> Bool in guard !closed else { return false }; closed = true; return true }
        guard first else { return }
        Darwin.shutdown(command.fileDescriptor, SHUT_RDWR); Darwin.shutdown(frames.fileDescriptor, SHUT_RDWR)
        DispatchQueue.main.async { [self] in onClosed(); application.terminate() }
    }
    @MainActor var hasTerminated: Bool { application.isTerminated }
    @MainActor func close() {
        lock.withLock { closed = true }
        Darwin.shutdown(command.fileDescriptor, SHUT_RDWR); Darwin.shutdown(frames.fileDescriptor, SHUT_RDWR)
        application.terminate()
    }
}
