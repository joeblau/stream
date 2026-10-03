import AppKit
import CoreMedia
import CoreVideo

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
    }
    struct Statistics: Codable, Sendable {
        var receivedFrames = 0, rejectedFrames = 0, shedRequests = 0
        var maximumReceivedFrameBytes = 0
        var maximumSnapshotLatencyMilliseconds = 0.0
    }
    private struct Demand { var generation: UUID; var command: BrowserWidgetAudioCommand; var callbacks: Callbacks }
    private struct PendingFrame { var widget: UUID; var generation: UUID; var request: UUID; var timeout: Timer }
    let requiredSystemAudioExclusions = Set([BrowserWidgetAudioIdentity.helperBundleID])
    let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
    private(set) var failure: String?
    private(set) var statistics = Statistics()
    private(set) var lastFrameHeader: BrowserWidgetVisualHeader?
    var demandCount: Int { demands.count }
    /// Qualification runtime owners can include this identity when reconciling mixer channels.
    /// The existing product `.web` keys do not yet register an audio channel automatically.
    var demandedAudioChannels: Set<AudioChannelID> { demands.isEmpty ? [] : [channel] }
    var helperPID: Int32? { connection?.pid }
    var audioIsCapturing: Bool { audio.isCapturing }
    private let applicationURL: URL
    private let audio: BrowserWidgetAudioCapture
    private let mixer: AudioMixEngine?
    private var connection: BrowserWidgetHelperConnection?
    private var launchTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var epoch = UUID()
    private var demands: [UUID: Demand] = [:]
    private var pools: [UUID: CVPixelBufferPool] = [:]
    private var pendingFrame: PendingFrame?
    private var evaluations: [UUID: CheckedContinuation<String?, Never>] = [:]

    init(applicationURL: URL, mixer: AudioMixEngine? = nil,
         audioSink: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.applicationURL = applicationURL; self.mixer = mixer
        audio = BrowserWidgetAudioCapture(mixer: mixer, sink: audioSink)
        audio.onFailure = { [weak self] category in self?.failSession(category) }
    }
    convenience init(applicationURL: URL, mixer: AudioMixEngine) {
        let channel = AudioChannelID.application(bundleID: BrowserWidgetAudioIdentity.helperBundleID)
        self.init(applicationURL: applicationURL, mixer: mixer) { mixer.enqueue(channel, $0) }
    }
    /// Packaged helper lookup has no launch or permission side effects.
    static func packagedHelperURL(bundle: Bundle = .main) -> URL? {
        let candidate = bundle.bundleURL.appendingPathComponent("Contents/Helpers/StreamBrowserAudioHelper.app")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func loadForQualification(id: UUID, generation: UUID, html: String? = nil, url: URL? = nil,
                              options: BrowserWidgetPageOptions, callbacks: Callbacks) async throws {
        let command = BrowserWidgetAudioCommand(action: .load, widgetID: id, html: html, url: url,
                                               options: options, generation: generation)
        try command.validate()
        guard demands[id] != nil || demands.count < BrowserWidgetAudioCommand.maximumWidgets else { throw SessionError.widgetLimit }
        if let shutdownTask { await shutdownTask.value; self.shutdownTask = nil }
        failure = nil
        demands[id] = Demand(generation: generation, command: command, callbacks: callbacks)
        pools[id] = nil
        cancelSnapshot(for: id)
        callbacks.state(.loading)
        do {
            try await ensureLaunched()
            guard demands[id]?.generation == generation else { return }
            try connection?.send(command)
        } catch {
            guard demands[id]?.generation == generation else { throw error }
            callbacks.state(.failed("The browser helper couldn't start. Independent audio remains unavailable."))
            release(id)
            throw error
        }
    }

    /// Last demand owns shutdown; a new demand waits for capture/socket/holdback cleanup first.
    func release(_ id: UUID) {
        guard demands.removeValue(forKey: id) != nil else { return }
        pools[id] = nil; cancelSnapshot(for: id)
        try? connection?.send(.init(action: .stop, widgetID: id))
        if demands.isEmpty { beginShutdown() }
    }
    func waitUntilStopped() async { await shutdownTask?.value }

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
        guard let demand = demands[id] else { return }
        try? connection?.send(.init(action: suspended ? .suspend : .resume, widgetID: id, generation: demand.generation))
    }

    private func ensureLaunched() async throws {
        if connection != nil { return }
        if let launchTask { try await launchTask.value; return }
        // Fail before loading an audible page; preflight never requests or modifies permission.
        guard CGSessionCopyCurrentDictionary() != nil, CGPreflightScreenCaptureAccess() else { throw SessionError.unavailable }
        let expected = epoch
        let task = Task {
            let connection = try await BrowserWidgetHelperConnection.launch(applicationURL: applicationURL,
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
            if !audio.isCapturing, audioTask == nil, let pid = connection?.pid {
                audioTask = Task { [weak self] in
                    guard let self else { return }
                    await mixer?.addChannel(channel)
                    do { try await audio.startForQualification(helperPID: pid) }
                    catch { if self.epoch == expected { failSession("helper_audio_unavailable") } }
                    if self.epoch == expected { audioTask = nil }
                }
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
        failure = category
        for demand in demands.values { demand.callbacks.state(.failed("The browser helper stopped. Independent audio remains unavailable.")) }
        demands.removeAll(); pools.removeAll(); beginShutdown()
    }
    private func beginShutdown() {
        guard shutdownTask == nil else { return }
        epoch = UUID()
        pendingFrame?.timeout.invalidate(); pendingFrame = nil
        for continuation in evaluations.values { continuation.resume(returning: nil) }; evaluations.removeAll()
        shutdownTask = Task { [self] in
            launchTask?.cancel(); try? await launchTask?.value; launchTask = nil
            try? connection?.send(.init(action: .close)); connection?.close(); connection = nil
            audioTask?.cancel(); await audioTask?.value; audioTask = nil
            await audio.stop(); await mixer?.removeChannel(channel)
        }
    }
}

/// Separate bounded command and frame connections keep visual readback off audio queues. Both
/// accepted peers must match the exact LaunchServices PID. Readers deliver at most one item to
/// MainActor at a time; socket closure wakes them, and command writes have a 256 KiB / 64-item cap.
private final class BrowserWidgetHelperConnection: @unchecked Sendable {
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
    @MainActor static func launch(applicationURL: URL, onReply: @escaping @MainActor @Sendable (BrowserWidgetAudioReply) -> Void,
                       onFrame: @escaping @MainActor @Sendable (BrowserWidgetVisualHeader, Data) -> Void,
                       onClosed: @escaping @MainActor @Sendable () -> Void) async throws -> BrowserWidgetHelperConnection {
        let commandListener = try BrowserWidgetAudioSocket(), frameListener = try BrowserWidgetAudioSocket()
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--ipc-socket", commandListener.path, "--frame-socket", frameListener.path]
        config.activates = false; config.createsNewApplicationInstance = true; config.addsToRecentItems = false
        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: config)
        guard application.bundleIdentifier == BrowserWidgetAudioIdentity.helperBundleID else { application.terminate(); throw BrowserWidgetHelperSession.SessionError.unavailable }
        do {
            let command = try await commandListener.accept(expectedPID: application.processIdentifier)
            let frames = try await frameListener.accept(expectedPID: application.processIdentifier)
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
    @MainActor func close() {
        lock.withLock { closed = true }
        Darwin.shutdown(command.fileDescriptor, SHUT_RDWR); Darwin.shutdown(frames.fileDescriptor, SHUT_RDWR)
        application.terminate()
    }
}
