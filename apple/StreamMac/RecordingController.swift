import AppKit
import AVFoundation
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
    @Published var context = RecordingContext()
    @Published private(set) var folderLabel = "App Group Recordings"
    @Published var preferences: RecordingPreferences {
        didSet { persistPreferences() }
    }

    var isRecording: Bool { state.isRecording }
    var canSplit: Bool { state == .recording && finishingSegments == 0 }
    var currentOutputURL: URL? { session?.outputURL }
    var activeOutputURLs: Set<URL> {
        guard let session else { return finishingURLs }
        return finishingURLs.union([session.outputURL]).union((isolatedGroup?.files ?? []).map {
            session.outputURL.deletingLastPathComponent().appendingPathComponent($0)
        })
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

    init(defaults: UserDefaults = .standard, defaultDirectory: URL? = nil) {
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
        let url = directory.appendingPathComponent("recording-preferences.json")
        guard url != preferencesURL else { return }
        loadingPreferences = true
        defer { loadingPreferences = false }
        preferencesURL = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                preferences = try JSONDecoder().decode(RecordingPreferences.self, from: Data(contentsOf: url))
            } else {
                let migrated = defaults.bool(forKey: "recording.profilePreferencesMigrated.v1")
                preferences = migrated ? .init() : defaults.data(forKey: "recording.preferences.v1")
                    .flatMap { try? JSONDecoder().decode(RecordingPreferences.self, from: $0) } ?? .init()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
                defaults.set(true, forKey: "recording.profilePreferencesMigrated.v1")
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
        folderLabel = "App Group Recordings"
    }

    func toggle(stream: StreamController) { canStop ? stop() : start(stream: stream) }

    func start(stream: StreamController, useCountdown: Bool = true) {
        guard !state.isActive, session == nil, finishingSegments == 0 else { return }
        lastError = nil; warning = nil; progress = .init(); isolatedProgress = []; unavailableTrackIDs = []
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
            let session = try makeSegment(stream: stream)
            self.session = session
            router.install(session)
            isolatedRouter.install(isolatedGroup)
            let router = router
            frameSubscription = stream.addFrameSink { frame in router.appendVideo(frame.sampleBuffer) }
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
            stream.noteRecordingStarted()
        } catch {
            lastError = error.localizedDescription
            state = .failed(lastError!)
            self.stream = nil
            completeStopsIfReady()
        }
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
        isolatedGroup = group; configuration.isolatedFiles = group.files
        return ProgramRecordingSession(outputURL: url, configuration: configuration, timeline: timeline, event: { [weak self] event in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                switch event {
                case .recording:
                    if self.state == .preparing { self.state = .recording }
                case .paused:
                    if self.state == .recording { self.state = .paused }
                case .progress(let progress):
                    self.progress = progress
                    self.warning = progress.warning ?? self.isolatedProgress.first(where: { $0.error != nil }).map { "\($0.name): \($0.error!)" }
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

    func pause() { guard state == .recording else { return }; session?.pause() }
    func resume() {
        guard state == .paused else { return }
        state = .preparing
        session?.resume()
    }

    func startNewFile() {
        guard canSplit, let previous = session, let stream else { return }
        let previousIsolated = isolatedGroup
        let previousURLs = Set([previous.outputURL] + (previousIsolated?.files ?? []).map {
            previous.outputURL.deletingLastPathComponent().appendingPathComponent($0)
        })
        do {
            let next = try makeSegment(stream: stream)
            session = next; router.install(next)
            isolatedRouter.install(isolatedGroup); previousIsolated?.deactivate()
            finishingSegments += 1
            finishingURLs.formUnion(previousURLs)
            previous.finish { [weak self, store] result in
                if result.completed { store.markComplete(result.url) }
                previousIsolated?.finish {
                    Task { @MainActor in
                        guard let self else { return }
                        self.finishingSegments -= 1
                        self.finishingURLs.subtract(previousURLs)
                        self.acceptFinished(result, final: false)
                        self.completeStopsIfReady()
                    }
                }
            }
        } catch { warning = "Cannot start a new recording file: \(error.localizedDescription)" }
    }

    /// Normal app termination waits for this completion, including any previous
    /// segment still finishing. Pausing/rotating never touches network outputs.
    func stop(completion: (() -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        countdownTask?.cancel(); countdownTask = nil; countdownRemaining = 0
        guard let session else {
            if state == .preparing { state = .idle; stream = nil }
            completeStopsIfReady(); return
        }
        guard state != .stopping else { return }
        state = .stopping
        router.install(nil)
        isolatedRouter.install(nil); isolatedGroup?.deactivate()
        for subscription in isolatedSubscriptions { stream?.removeAudioTap(subscription) }
        isolatedSubscriptions.removeAll()
        if let frameSubscription { stream?.removeFrameSink(frameSubscription) }
        if let audioSubscription { stream?.removeAudioTap(audioSubscription) }
        frameSubscription = nil; audioSubscription = nil
        stream?.noteRecordingStopped(); stream = nil
        let id = sessionID
        let isolated = isolatedGroup
        session.finish { [weak self, store] result in
            if result.completed { store.markComplete(result.url) }
            isolated?.finish {
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.session = nil; self.isolatedGroup = nil
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
        guard session == nil, countdownTask == nil, finishingSegments == 0 else { return }
        folderAccess?.stopAccessingSecurityScopedResource(); folderAccess = nil
        if state == .stopping { state = pendingStopState }
        let completions = stopCompletions; stopCompletions.removeAll()
        completions.forEach { $0() }
    }
}

private enum RecordingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
