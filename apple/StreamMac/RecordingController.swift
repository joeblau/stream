import AppKit
import AVFoundation
import Combine
import StreamCore

/// Independent program recording. One pair of taps survives file changes, and
/// actual writer events drive the visible lifecycle.
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingSessionState = .idle
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastPartialRecordingURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var warning: String?
    @Published private(set) var progress = ProgramRecordingSession.Progress()
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var isolatedProgress: [IsolatedTrackProgress] = []
    @Published private(set) var isolatedVideoProgress: [IsolatedVideoProgress] = []
    @Published private(set) var videoBudget: IsolatedVideoBudget?
    @Published var context = RecordingContext()
    @Published private(set) var chatSummary: RecordingChatSummary?
    let chatFeed = RecordingChatFeed()
    var chatSubscriptions: Set<AnyCancellable> = []
    private var chatArchive: RecordingChatArchive?
    @Published private(set) var folderLabel = "Default recordings folder"
    @Published var preferences: RecordingPreferences {
        didSet { persistPreferences() }
    }

    var isRecording: Bool { state.isRecording }
    @Published private var pausePending = false
    var canSplit: Bool { state == .recording && !pausePending && finishingSegments == 0 }
    var currentOutputURL: URL? { session?.outputURL }
    var activeOutputURLs: Set<URL> {
        guard let session else { return finishingURLs.filter { !$0.lastPathComponent.hasSuffix(".chat.jsonl") } }
        return finishingURLs.union([session.outputURL]).union((isolatedGroup?.files ?? []).map {
            session.outputURL.deletingLastPathComponent().appendingPathComponent($0)
        }).union((isolatedVideoGroup?.files ?? []).map { session.outputURL.deletingLastPathComponent().appendingPathComponent($0) })
            .filter { !$0.lastPathComponent.hasSuffix(".chat.jsonl") }
    }
    var canStop: Bool { state.isActive && state != .stopping }

    private let defaults: UserDefaults
    private let defaultDirectory: URL?
    private var preferencesURL: URL?
    private var loadingPreferences = false
    private var store: RecordingStore
    private let router = ProgramRecordingRouter()
    private let isolatedRouter = IsolatedRecordingRouter()
    private var isolatedGroup: IsolatedRecordingGroup?
    private var isolatedSubscriptions: [StreamController.AudioTapSubscription] = []
    private var unavailableTrackIDs: Set<String> = []
    private let isolatedVideoRouter = IsolatedVideoRouter()
    private var isolatedVideoGroup: IsolatedVideoGroup?
    private var videoSources: [String: IsolatedVideoSource] = [:]
    private var unavailableVideoSourceReasons: [String: String] = [:]
    private var videoSubscriptions: [StreamController.RecordingVideoSubscription] = []
    private var unavailableVideoAudioIDs: Set<String> = []
    private var videoPreflightTask: Task<Void, Never>?
    private weak var demandStream: StreamController?
    private weak var reservationStream: StreamController?
    private let encoderReservationID = UUID()
    let outputCanvas: OutputCanvas
    private var ownsPipelineDemand = false
    var activeIsolatedVideoEncoderCount: Int { state.isActive ? videoSources.count : 0 }
    /// Go Live/add-destination preflight can reject a new publisher before
    /// it consumes encoder sessions already owned by isolated recording.
    var maximumPublishingEncodersWhileRecording: Int? {
        guard state.isActive, !videoSources.isEmpty, let videoBudget else { return nil }
        return max(0, videoBudget.maximumEncoderSessions - 1 - videoSources.count)
    }
    private var session: ProgramRecordingSession?
    private weak var stream: StreamController?
    private var frameSubscription: StreamController.FrameSubscription?
    private var audioSubscription: StreamController.AudioTapSubscription?
    private var sessionID = UUID()
    private var recordingID = UUID()
    private var segmentIndex = 0
    private var finishingSegments = 0
    private var finishingURLs: Set<URL> = []
    private var pendingStopState: RecordingSessionState = .idle
    private var countdownTask: Task<Void, Never>?
    private var folderAccess: URL?
    private var activePreferences = RecordingPreferences()
    private var activeContext = RecordingContext()
    private var stopCompletions: [() -> Void] = []

    init(defaults: UserDefaults = .standard, defaultDirectory: URL? = nil, outputCanvas: OutputCanvas = .program) {
        self.outputCanvas = outputCanvas
        self.defaults = defaults
        self.defaultDirectory = defaultDirectory
        self.store = RecordingStore(directory: defaultDirectory)
        preferences = defaults.data(forKey: "recording.preferences.v1")
            .flatMap { try? JSONDecoder().decode(RecordingPreferences.self, from: $0) } ?? .init()
        if let data = defaults.data(forKey: "recording.folderBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                folderLabel = url.path
            }
        }
    }

    /// Profile activation supplies its directory. Folder access remains a
    /// machine bookmark; recording choices and stable isolated IDs belong to
    /// the profile. Migrate old machine presets into the first profile once.
    func loadPreferences(directory: URL) {
        guard !state.isActive, session == nil else { return }
        let url = directory.appendingPathComponent(outputCanvas == .program ? "recording-preferences.json" : "secondary-recording-preferences.json")
        guard url != preferencesURL else { return }
        loadingPreferences = true
        defer { loadingPreferences = false }
        preferencesURL = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                preferences = try JSONDecoder().decode(RecordingPreferences.self, from: Data(contentsOf: url))
            } else {
                let migrated = defaults.bool(forKey: "recording.profilePreferencesMigrated.v1")
                preferences = migrated || outputCanvas == .secondary ? .init() : defaults.data(forKey: "recording.preferences.v1")
                    .flatMap { try? JSONDecoder().decode(RecordingPreferences.self, from: $0) } ?? .init()
                if outputCanvas == .secondary { preferences.filenamePrefix = "Secondary" }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
                if outputCanvas == .program { defaults.set(true, forKey: "recording.profilePreferencesMigrated.v1") }
            }
        } catch {
            preferences = .init()
            lastError = "Recording preferences could not be loaded: \(error.localizedDescription)"
        }
    }

    private func persistPreferences() {
        guard !loadingPreferences else { return }
        do {
            let data = try JSONEncoder().encode(preferences)
            if let preferencesURL { try data.write(to: preferencesURL, options: .atomic) }
            else { defaults.set(data, forKey: "recording.preferences.v1") }
        } catch { lastError = "Recording preferences could not be saved: \(error.localizedDescription)" }
    }

    func libraryAccess() throws -> RecordingDirectoryAccess {
        if let data = defaults.data(forKey: "recording.folderBookmark") {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw RecordingError.message("Recording folder access was lost. Choose the folder again.") }
            return RecordingDirectoryAccess(url: url, scoped: true)
        }
        guard let directory = RecordingStore(directory: defaultDirectory).ensureRecordingsDirectory() else {
            throw RecordingError.message("The recordings folder is unavailable.")
        }
        return RecordingDirectoryAccess(url: directory, scoped: false)
    }

    func storagePreflight() -> RecordingStoragePreflight {
        var scopedURL: URL?
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        do {
            let directory: URL?
            if let folderAccess { directory = folderAccess }
            else if let data = defaults.data(forKey: "recording.folderBookmark") {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw RecordingError.message("Recording folder access was lost. Choose the folder again.") }
                scopedURL = url; directory = url
            } else { directory = RecordingStore(directory: defaultDirectory).ensureRecordingsDirectory() }
            guard let directory else { throw RecordingError.message("The recordings folder is unavailable.") }
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return RecordingStoragePreflight(directory: directory, availableBytes: nil, isWritable: false, error: "The recording volume or folder is unavailable.")
            }
            let writable = FileManager.default.isWritableFile(atPath: directory.path)
            let bytes = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity.map(Int64.init)
            return RecordingStoragePreflight(directory: directory, availableBytes: bytes, isWritable: writable,
                error: writable ? nil : "The recording folder is not writable.")
        } catch {
            return RecordingStoragePreflight(directory: scopedURL, availableBytes: nil, isWritable: false, error: error.localizedDescription)
        }
    }

    func chooseFolder() {
        guard !state.isActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Use Recording Folder"
        panel.message = "Choose a writable recording folder, including a mounted external volume."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: "recording.folderBookmark")
            folderLabel = url.path
            lastError = nil
        } catch { lastError = "Cannot retain access to the recording folder: \(error.localizedDescription)" }
    }

    func useDefaultFolder() {
        guard !state.isActive else { return }
        defaults.removeObject(forKey: "recording.folderBookmark")
        folderLabel = "Default recordings folder"
    }

    func toggle(stream: StreamController) { canStop ? stop() : start(stream: stream) }

    func start(stream: StreamController, useCountdown: Bool = true) {
        guard !state.isActive, session == nil, finishingSegments == 0 else { return }
        if let error = stream.reserveRecordingEncoders(encoderReservationID, count: 1 + preferences.isolatedVideoTracks.count, canvas: outputCanvas) {
            lastError = error; state = .failed(error); return
        }
        reservationStream = stream
        lastError = nil; warning = nil; progress = .init(); isolatedProgress = []; isolatedVideoProgress = []; pausePending = false
        unavailableTrackIDs = []; unavailableVideoAudioIDs = []; videoBudget = nil
        self.stream = stream
        recordingID = UUID(); segmentIndex = 0
        activePreferences = preferences
        activeContext = context
        state = .preparing
        let seconds = useCountdown ? min(60, max(0, activePreferences.countdownSeconds)) : 0
        if seconds > 0 {
            countdownRemaining = seconds
            countdownTask = Task { @MainActor [weak self, weak stream] in
                guard let self else { return }
                for remaining in stride(from: seconds, through: 1, by: -1) {
                    self.countdownRemaining = remaining
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                self.countdownRemaining = 0; self.countdownTask = nil
                guard let stream else { self.state = .idle; self.completeStopsIfReady(); return }
                self.begin(stream: stream)
            }
        } else { begin(stream: stream) }
    }

    private func begin(stream: StreamController) {
        do {
            store = try resolveStore()
            guard store.hasSufficientSpace() else { throw RecordingError.message("Not enough disk space to record (1 GB minimum).") }
            guard !activePreferences.isolatedVideoTracks.isEmpty else { try beginPrepared(stream: stream); return }
            var budget = IsolatedVideoBudget.current
            budget.publishingEncoders = stream.activePublishingEncoderCount
            budget.selectedEncoders = activePreferences.isolatedVideoTracks.count
            // Program maximum plus ISO bitrates and all independently
            // selected audio files; include room for two-second fragments.
            budget.estimatedDiskMegabytesPerSecond = Double(24_000_000 + activePreferences.isolatedVideoTracks.reduce(0) { $0 + $1.bitrate + 160_000 }
                + activePreferences.isolatedTracks.reduce(0) { $0 + ($1.format == .wav ? 3_072_000 : 160_000) }) / 8_000_000
            if let error = budget.rejection(programWidth: stream.activeProfile.canvasWidth, programHeight: stream.activeProfile.canvasHeight,
                programFPS: stream.activeProfile.frameRate, selections: activePreferences.isolatedVideoTracks) { throw RecordingError.message(error) }
            guard let directory = storagePreflight().directory else { throw RecordingError.message("The recording folder is unavailable.") }
            let id = recordingID
            videoPreflightTask = Task { @MainActor [weak self, weak stream] in
                do {
                    let measured = try await Task.detached(priority: .utility) { try RecordingVideoStorageProbe.measure(directory) }.value
                    guard let self, let stream, !Task.isCancelled, self.recordingID == id, self.state == .preparing else { return }
                    budget.measuredDiskMegabytesPerSecond = measured; budget.publishingEncoders = stream.activePublishingEncoderCount
                    self.videoBudget = budget; self.videoPreflightTask = nil
                    if let error = budget.rejection(programWidth: stream.activeProfile.canvasWidth, programHeight: stream.activeProfile.canvasHeight,
                        programFPS: stream.activeProfile.frameRate, selections: self.activePreferences.isolatedVideoTracks) { throw RecordingError.message(error) }
                    try self.beginPrepared(stream: stream)
                } catch {
                    guard let self, !Task.isCancelled, self.recordingID == id else { return }
                    self.lastError = error.localizedDescription; self.state = .failed(error.localizedDescription)
                    self.videoPreflightTask = nil; self.stream = nil; self.completeStopsIfReady()
                }
            }
        } catch {
            lastError = error.localizedDescription; state = .failed(lastError!); self.stream = nil; completeStopsIfReady()
        }
    }

    private func beginPrepared(stream: StreamController) throws {
            demandStream = stream
            let catalog = stream.recordingVideoSources()
            for selection in activePreferences.isolatedVideoTracks {
                if let (token, source) = stream.addRecordingVideoSource(targetID: selection.targetID) {
                    videoSubscriptions.append(token); videoSources[selection.targetID] = source
                } else { unavailableVideoSourceReasons[selection.targetID] = catalog.first { $0.id == selection.targetID }?.unsupportedReason }
            }
            let session = try makeSegment(stream: stream)
            self.session = session
            router.install(session)
            chatFeed.install(chatArchive)
            isolatedRouter.install(isolatedGroup)
            isolatedVideoRouter.install(isolatedVideoGroup)
            let router = router
            frameSubscription = stream.addFrameSink(canvas: outputCanvas) { frame in router.appendVideo(frame.sampleBuffer) }
            audioSubscription = stream.addProgramAudioTap { sample in router.appendAudio(sample) }
            let isolatedRouter = isolatedRouter
            for selection in activePreferences.isolatedTracks {
                let targetID = selection.targetID
                if let tap = stream.addRecordingAudioTap(targetID: targetID, processing: selection.processing, sink: { sample in
                    isolatedRouter.append(sample, targetID: targetID)
                }) { isolatedSubscriptions.append(tap) }
                else {
                    unavailableTrackIDs.insert(targetID)
                    isolatedGroup?.fail(targetID: targetID, message: "The selected audio source is unavailable or was deleted.")
                }
            }
            let videoRouter = isolatedVideoRouter
            for selection in activePreferences.isolatedVideoTracks {
                guard let audioID = selection.audioTargetID else { continue }
                if let tap = stream.addRecordingAudioTap(targetID: audioID, processing: .afterEffects, sink: { sample in
                    videoRouter.appendAudio(sample, videoTargetID: selection.targetID)
                }) { isolatedSubscriptions.append(tap) }
                else {
                    unavailableVideoAudioIDs.insert(selection.targetID)
                    isolatedVideoGroup?.fail(targetID: selection.targetID, message: "The associated audio source is unavailable or was deleted.")
                }
            }
            stream.noteRecordingStarted(canvas: outputCanvas)
            ownsPipelineDemand = true
    }

    private func resolveStore() throws -> RecordingStore {
        guard let data = defaults.data(forKey: "recording.folderBookmark") else { return RecordingStore(directory: defaultDirectory) }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        // Do not silently fall back when an external folder disappears.
        guard url.startAccessingSecurityScopedResource() else { throw RecordingError.message("Recording folder access was lost. Choose the folder again.") }
        folderAccess = url
        if stale {
            defaults.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "recording.folderBookmark")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw RecordingError.message("The recording volume or folder is unavailable.") }
        return RecordingStore(directory: url)
    }

    private func makeSegment(stream: StreamController) throws -> ProgramRecordingSession {
        guard let url = store.makeRecordingURL(date: Date(), prefix: activePreferences.filenamePrefix, fileExtension: activePreferences.container.rawValue) else {
            throw RecordingError.message("The recordings folder is unavailable.")
        }
        guard activePreferences.isolatedTracks.count <= 8 else {
            throw RecordingError.message("Choose at most eight isolated tracks for this recording.")
        }
        segmentIndex += 1
        let id = UUID(); sessionID = id
        state = .preparing; progress = .init()
        var configuration = ProgramRecordingSession.Configuration()
        configuration.frameRate = stream.activeProfile.frameRate
        configuration.container = activePreferences.container
        configuration.codec = activePreferences.codec
        configuration.quality = activePreferences.quality
        configuration.sessionID = recordingID.uuidString
        configuration.segmentIndex = segmentIndex
        configuration.context = activeContext
        let timeline = RecordingTimeline()
        chatSummary = nil; chatArchive = nil
        if activePreferences.chatArchive.enabled {
            let archive = RecordingChatArchive(programURL: url, sessionID: recordingID.uuidString, segmentIndex: segmentIndex,
                context: activeContext, timeline: timeline, preferences: activePreferences.chatArchive) { [weak self] summary in
                Task { @MainActor in
                    guard let self else { return }
                    if self.sessionID == id { self.chatSummary = summary }
                    if let warning = summary.warning { self.warning = warning }
                }
            }
            chatArchive = archive; configuration.chatArchiveFile = archive.url.lastPathComponent
            let feed = chatFeed
            configuration.onVideoAccepted = { [feed, archive] frame in feed.frame(frame, into: archive) }
            configuration.onMarkerRecorded = { [archive] marker in archive.marker(marker) }
            if segmentIndex == 1, let directory = storagePreflight().directory {
                let prefs = activePreferences.chatArchive, context = activeContext
                Task.detached(priority: .utility) {
                    try? RecordingChatReader.applyRetention(directory: directory, context: context, days: prefs.retentionDays)
                }
            }
        }
        isolatedProgress = activePreferences.isolatedTracks.map {
            IsolatedTrackProgress(id: $0.targetID, name: $0.name, file: "")
        }
        let group = IsolatedRecordingGroup(programURL: url, selections: activePreferences.isolatedTracks,
            sessionID: recordingID.uuidString, segmentIndex: segmentIndex, context: activeContext, timeline: timeline) { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                guard self.sessionID == id else {
                    if progress.status == "failed" { self.warning = "Previous isolated track failed: \(progress.name): \(progress.error ?? "write failure")" }
                    return
                }
                if let index = self.isolatedProgress.firstIndex(where: { $0.id == progress.id }) { self.isolatedProgress[index] = progress }
                if let error = progress.error { self.warning = "\(progress.name): \(error)" }
            }
        }
        for targetID in unavailableTrackIDs {
            group.fail(targetID: targetID, message: "The selected audio source is unavailable or was deleted.")
        }
        isolatedVideoProgress = activePreferences.isolatedVideoTracks.map { .init(id: $0.targetID, name: $0.name, file: "") }
        let videoGroup = IsolatedVideoGroup(programURL: url, selections: activePreferences.isolatedVideoTracks, sources: videoSources,
            unavailableSourceReasons: unavailableVideoSourceReasons,
            sessionID: recordingID.uuidString, segmentIndex: segmentIndex, context: activeContext, budget: videoBudget ?? .current,
            timeline: timeline) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.sessionID == id else {
                        if progress.error != nil { self.warning = "Previous isolated video failed: \(progress.name): \(progress.error!)" }; return
                    }
                    if let index = self.isolatedVideoProgress.firstIndex(where: { $0.id == progress.id }) { self.isolatedVideoProgress[index] = progress }
                    if let error = progress.error ?? progress.warning { self.warning = "\(progress.name): \(error)" }
                }
            }
        for targetID in unavailableVideoAudioIDs { videoGroup.fail(targetID: targetID, message: "The associated audio source is unavailable or was deleted.") }
        isolatedGroup = group; isolatedVideoGroup = videoGroup; configuration.isolatedFiles = group.files + videoGroup.files
        return ProgramRecordingSession(outputURL: url, configuration: configuration, timeline: timeline, event: { [weak self] event in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                switch event {
                case .recording:
                    if self.state == .preparing { self.state = .recording }
                case .paused:
                    self.pausePending = false
                    if self.state == .recording { self.state = .paused }
                case .progress(let progress):
                    self.progress = progress
                    self.warning = progress.warning ?? self.chatSummary?.warning ?? self.isolatedProgress.first(where: { $0.error != nil }).map { "\($0.name): \($0.error!)" }
                        ?? self.isolatedVideoProgress.first(where: { $0.error != nil || $0.warning != nil }).map { "\($0.name): \($0.error ?? $0.warning!)" }
                    if self.canSplit,
                       (self.activePreferences.splitAfterMinutes > 0 && progress.durationSeconds >= Double(self.activePreferences.splitAfterMinutes) * 60)
                        || (self.activePreferences.splitAfterMegabytes > 0 && progress.bytesWritten >= Int64(self.activePreferences.splitAfterMegabytes) * 1_000_000) {
                        self.startNewFile()
                    }
                case .failed(let message):
                    self.lastError = message; self.stop()
                }
            }
        })
    }

    func addMarker(title: String) {
        guard state == .recording || state == .paused else { return }
        session?.addMarker(title: title)
    }

    func pause() {
        guard state == .recording, !pausePending else { return }
        pausePending = true; session?.pause()
    }
    func resume() {
        guard state == .paused else { return }
        state = .preparing
        session?.resume()
    }

    func startNewFile() {
        guard canSplit, let previous = session, let stream else { return }
        let rotationReservation = UUID()
        if let error = stream.reserveRecordingEncoders(rotationReservation, count: 1 + videoSources.count, canvas: outputCanvas) {
            warning = "Cannot rotate recording: \(error)"; return
        }
        let previousIsolated = isolatedGroup
        let previousVideo = isolatedVideoGroup
        let previousChat = chatArchive
        let previousURLs = Set([previous.outputURL] + ((previousIsolated?.files ?? []) + (previousVideo?.files ?? [])).map {
            previous.outputURL.deletingLastPathComponent().appendingPathComponent($0)
        }).union(previousChat.map { [$0.url] } ?? [])
        do {
            let next = try makeSegment(stream: stream)
            session = next; router.rotate(to: next, finishing: previous); chatFeed.install(chatArchive)
            isolatedRouter.retire(previousIsolated, installing: isolatedGroup)
            isolatedVideoRouter.retire(previousVideo, installing: isolatedVideoGroup)
            finishingSegments += 1
            finishingURLs.formUnion(previousURLs)
            let router = self.router
            let isolatedRouter = self.isolatedRouter; let isolatedVideoRouter = self.isolatedVideoRouter
            previous.finish(waitingForSourceBoundary: true) { [weak self, store, router] result in
                router.finished(previous)
                if result.completed { store.markComplete(result.url) }
                RecordingController.finishAssociated(audio: previousIsolated, video: previousVideo, chat: previousChat, completed: result.completed) {
                    isolatedRouter.finished(previousIsolated); isolatedVideoRouter.finished(previousVideo)
                    Task { @MainActor in
                        stream.releaseRecordingEncoders(rotationReservation)
                        guard let self else { return }
                        self.finishingSegments -= 1
                        self.finishingURLs.subtract(previousURLs)
                        self.acceptFinished(result, final: false)
                        self.completeStopsIfReady()
                    }
                }
            }
        } catch {
            stream.releaseRecordingEncoders(rotationReservation)
            warning = "Cannot start a new recording file: \(error.localizedDescription)"
        }
    }

    /// Normal app termination waits for this completion, including any previous
    /// segment still finishing. Pausing/rotating never touches network outputs.
    func stop(completion: (() -> Void)? = nil) {
        pausePending = false
        if let completion { stopCompletions.append(completion) }
        countdownTask?.cancel(); countdownTask = nil; countdownRemaining = 0
        videoPreflightTask?.cancel(); videoPreflightTask = nil
        guard let session else {
            if state == .preparing { state = .idle; stream = nil }
            completeStopsIfReady(); return
        }
        guard state != .stopping else { return }
        state = .stopping
        router.stop(session); chatFeed.install(nil)
        isolatedRouter.retire(isolatedGroup, installing: nil)
        isolatedVideoRouter.retire(isolatedVideoGroup, installing: nil)
        let finalIsolatedSubscriptions = isolatedSubscriptions
        isolatedSubscriptions.removeAll()
        if let frameSubscription { stream?.removeFrameSink(frameSubscription) }
        let finalAudioSubscription = audioSubscription
        let finalStream = stream
        frameSubscription = nil; audioSubscription = nil
        stream = nil
        let id = sessionID
        let isolated = isolatedGroup
        let video = isolatedVideoGroup
        let chat = chatArchive
        let router = self.router
        let isolatedRouter = self.isolatedRouter; let isolatedVideoRouter = self.isolatedVideoRouter
        session.finish { [weak self, store, router] result in
            router.finished(session)
            if result.completed { store.markComplete(result.url) }
            RecordingController.finishAssociated(audio: isolated, video: video, chat: chat, completed: result.completed) {
                isolatedRouter.finished(isolated); isolatedVideoRouter.finished(video)
                Task { @MainActor in
                    if let finalAudioSubscription { finalStream?.removeAudioTap(finalAudioSubscription) }
                    for subscription in finalIsolatedSubscriptions { finalStream?.removeAudioTap(subscription) }
                    guard let self, self.sessionID == id else { return }
                    self.session = nil; self.isolatedGroup = nil; self.isolatedVideoGroup = nil; self.chatArchive = nil
                    self.progress = result.progress
                    self.acceptFinished(result, final: true)
                    self.completeStopsIfReady()
                }
            }
        }
    }

    private func acceptFinished(_ result: ProgramRecordingSession.Result, final: Bool) {
        if result.completed {
            lastRecordingURL = result.url
            if final { pendingStopState = .idle }
        } else {
            lastPartialRecordingURL = result.url
            lastError = result.error ?? "Recording finalization failed."
            if final { pendingStopState = .failed(lastError!) }
            else { warning = "Previous recording segment failed: \(lastError!)" }
        }
    }

    private func completeStopsIfReady() {
        guard session == nil, countdownTask == nil, videoPreflightTask == nil, finishingSegments == 0 else { return }
        reservationStream?.releaseRecordingEncoders(encoderReservationID); reservationStream = nil
        for subscription in videoSubscriptions { demandStream?.removeRecordingVideoSource(subscription) }
        videoSubscriptions.removeAll(); videoSources.removeAll(); unavailableVideoSourceReasons.removeAll()
        if ownsPipelineDemand { demandStream?.noteRecordingStopped(canvas: outputCanvas) }
        ownsPipelineDemand = false; demandStream = nil
        folderAccess?.stopAccessingSecurityScopedResource(); folderAccess = nil
        if state == .stopping { state = pendingStopState }
        let completions = stopCompletions; stopCompletions.removeAll()
        completions.forEach { $0() }
    }

    nonisolated private static func finishAssociated(audio: IsolatedRecordingGroup?, video: IsolatedVideoGroup?, chat: RecordingChatArchive?, completed: Bool,
        completion: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        if let audio { group.enter(); audio.finish { group.leave() } }
        if let video { group.enter(); video.finish { group.leave() } }
        if let chat { group.enter(); chat.finish(completed: completed) { group.leave() } }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }
}

private enum RecordingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
