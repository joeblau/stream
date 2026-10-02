import AVFoundation
import StreamCore

/// Independent program recording: capture callbacks hand buffers directly to
/// the writer's bounded mailboxes. Writer events, rather than button presses,
/// drive the visible lifecycle. Storage errors release only recording demand.
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingSessionState = .idle
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastPartialRecordingURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var warning: String?
    @Published private(set) var progress = ProgramRecordingSession.Progress()

    var isRecording: Bool { state.isRecording }

    private let store = RecordingStore()
    private var session: ProgramRecordingSession?
    private weak var stream: StreamController?
    private var frameSubscription: StreamController.FrameSubscription?
    private var audioSubscription: StreamController.AudioTapSubscription?
    private var sessionID = UUID()
    private var stopCompletions: [() -> Void] = []

    func toggle(stream: StreamController) {
        state.isActive ? stop() : start(stream: stream)
    }

    func start(stream: StreamController) {
        guard !state.isActive, session == nil else { return }
        lastError = nil; warning = nil; progress = .init()
        guard let url = store.makeRecordingURL(date: Date()) else {
            lastError = "The recordings folder is unavailable."
            state = .failed(lastError!); return
        }
        guard store.hasSufficientSpace() else {
            lastError = "Not enough disk space to record (1 GB minimum)."
            state = .failed(lastError!); return
        }
        let id = UUID(); sessionID = id
        state = .preparing
        var configuration = ProgramRecordingSession.Configuration()
        configuration.frameRate = stream.activeProfile.frameRate
        let session = ProgramRecordingSession(outputURL: url, configuration: configuration, event: { [weak self] event in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                switch event {
                case .recording:
                    if self.state == .preparing { self.state = .recording }
                case .progress(let progress):
                    self.progress = progress; self.warning = progress.warning
                case .failed(let message):
                    self.lastError = message
                    self.stop()
                }
            }
        })
        self.session = session
        self.stream = stream
        frameSubscription = stream.addFrameSink { frame in session.appendVideo(frame.sampleBuffer) }
        audioSubscription = stream.addProgramAudioTap { sample in session.appendAudio(sample) }
        stream.noteRecordingStarted()
    }

    /// Completion also gives app termination a chance to wait for finalization.
    /// Stopping preview leaves this demand intact until recording is stopped.
    func stop(completion: (() -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        guard let session else { completeStops(); return }
        guard state != .stopping else { return }
        state = .stopping
        if let frameSubscription { stream?.removeFrameSink(frameSubscription) }
        if let audioSubscription { stream?.removeAudioTap(audioSubscription) }
        frameSubscription = nil; audioSubscription = nil
        stream?.noteRecordingStopped(); stream = nil
        let id = sessionID
        session.finish { [weak self, store] result in
            if result.completed { store.markComplete(result.url) }
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                self.session = nil
                self.progress = result.progress
                if result.completed {
                    self.lastRecordingURL = result.url
                    self.state = .idle
                } else {
                    self.lastPartialRecordingURL = result.url
                    self.lastError = result.error ?? "Recording finalization failed."
                    self.state = .failed(self.lastError!)
                }
                self.completeStops()
            }
        }
    }

    private func completeStops() {
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }
}
