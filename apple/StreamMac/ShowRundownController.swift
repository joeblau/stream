import Combine
import Foundation
import StreamCore

struct ShowRundownEntry: Codable, Hashable, Identifiable, Sendable {
    var cue: RundownCue
    var transition: SceneTransition? = nil
    var id: UUID { cue.id }
}

struct ShowRundownDocument: Codable, Hashable, Sendable {
    var entries: [ShowRundownEntry] = []
    var loop = false
    var validationError: String? {
        guard entries.count <= 500 else { return "A rundown can have up to 500 entries." }
        guard Set(entries.map(\.id)).count == entries.count else { return "Rundown cue IDs must be unique." }
        return entries.compactMap { $0.cue.validationError ?? $0.transition?.validationError }.first
    }
}

@MainActor final class ShowRundownController: ObservableObject {
    @Published private(set) var document: ShowRundownDocument
    @Published private(set) var playback = RundownPlayback()
    @Published private(set) var remaining: Double?
    @Published private(set) var lastError: String?
    var onCue: ((ShowRundownEntry) -> Void)?
    private let url: URL?
    private let clock: () -> Double
    private let automaticallyTicks: Bool
    private var timer: Task<Void, Never>?
    private var pendingMediaEnd: Double?

    init(url: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
        .appendingPathComponent("studio-rundown.json"),
         clock: @escaping () -> Double = { DynamicOverlayStore.hostSeconds },
         automaticallyTicks: Bool = true) {
        self.url = url
        self.clock = clock
        self.automaticallyTicks = automaticallyTicks
        if let url, let data = try? Data(contentsOf: url),
           let restored = try? JSONDecoder().decode(ShowRundownDocument.self, from: data),
           restored.validationError == nil { document = restored }
        else { document = ShowRundownDocument() }
    }

    deinit { timer?.cancel() }

    func update(_ document: ShowRundownDocument) {
        guard document.validationError == nil else { lastError = document.validationError; return }
        stop()
        self.document = document
        lastError = nil
        guard let url else { return }
        do { try JSONEncoder().encode(document).write(to: url, options: .atomic) }
        catch { lastError = "The rundown could not be saved: \(error.localizedDescription)" }
    }

    func play() {
        let now = clock()
        if playback.phase == .running { return }
        lastError = nil
        if playback.phase == .paused {
            playback.resume(at: now)
            emit(playback.current)
        } else {
            emit(playback.start(cues: document.entries.map(\.cue), loop: document.loop,
                at: now, seed: UInt64.random(in: 0...UInt64.max)))
        }
        guard playback.phase == .running else { return }
        remaining = playback.remaining(at: now)
        if timer == nil && automaticallyTicks {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self else { return }
                    self.tick()
                }
            }
        }
    }

    func pause() {
        playback.pause(at: clock())
        remaining = playback.remaining(at: clock())
    }

    func stop() {
        timer?.cancel()
        timer = nil
        playback.stop()
        remaining = nil
        pendingMediaEnd = nil
    }

    func skip() {
        pendingMediaEnd = nil
        emit(playback.skip(at: clock()))
        if playback.phase == .finished { finish() }
    }

    func noteMediaEnd(at seconds: Double) {
        guard seconds.isFinite, seconds > playback.cueStartedAt,
              playback.phase == .running || playback.phase == .paused else { return }
        pendingMediaEnd = max(pendingMediaEnd ?? seconds, seconds)
    }

    func manualOverride() {
        pause()
        pendingMediaEnd = nil
    }

    func fail(_ message: String) { stop(); lastError = message }

    func tick() {
        let now = clock()
        let cue = playback.tick(at: now, mediaEndedAt: pendingMediaEnd)
        if let cue { pendingMediaEnd = nil; emit(cue) }
        remaining = playback.remaining(at: now)
        if playback.phase == .finished { finish() }
    }

    private func finish() { timer?.cancel(); timer = nil; remaining = nil; pendingMediaEnd = nil }

    private func emit(_ cue: RundownCue?) {
        guard let cue, let entry = document.entries.first(where: { $0.id == cue.id }) else { return }
        remaining = cue.durationSeconds
        onCue?(entry)
    }
}
