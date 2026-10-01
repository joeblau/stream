import Foundation

public struct RundownCue: Hashable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var sceneID: UUID
    /// Nil waits for media end or an explicit Skip.
    public var durationSeconds: Double?
    public var advanceOnMediaEnd: Bool
    /// Entries with the same nonempty group shuffle within their existing slots.
    public var randomGroup: String

    public init(id: UUID = UUID(), sceneID: UUID, durationSeconds: Double? = 60,
                advanceOnMediaEnd: Bool = false, randomGroup: String = "") {
        self.id = id
        self.sceneID = sceneID
        self.durationSeconds = durationSeconds
        self.advanceOnMediaEnd = advanceOnMediaEnd
        self.randomGroup = randomGroup
    }

    public var validationError: String? {
        if let durationSeconds, !durationSeconds.isFinite || !(0.1...86_400).contains(durationSeconds) {
            return "Cue duration must be between 0.1 and 86400 seconds."
        }
        return randomGroup.utf8.count <= 128 ? nil : "Random group names must be 128 bytes or fewer."
    }
}

/// One clock and one current cue; no independently scheduled scene timers.
/// All operations are explicit value mutations, so cancellation/late media
/// events and repeated transport calls can be tested without sleeping.
public struct RundownPlayback: Sendable {
    public enum Phase: String, Sendable { case idle, running, paused, finished }
    public private(set) var phase: Phase = .idle
    public private(set) var cues: [RundownCue] = []
    public private(set) var index = 0
    public private(set) var loop = false
    public private(set) var lap = 0
    public private(set) var cueStartedAt: Double = 0
    private var transport = TimerRuntimeState()
    private var original: [RundownCue] = []
    private var nextLap: [RundownCue] = []
    private var randomState: UInt64 = 1

    public init() {}
    public var current: RundownCue? { cues.indices.contains(index) ? cues[index] : nil }
    public var next: RundownCue? {
        if cues.indices.contains(index + 1) { return cues[index + 1] }
        return loop ? nextLap.first : nil
    }

    public mutating func start(cues: [RundownCue], loop: Bool, at now: Double,
                               seed: UInt64 = 1) -> RundownCue? {
        guard now.isFinite, !cues.isEmpty, cues.count <= 500,
              Set(cues.map(\.id)).count == cues.count,
              cues.allSatisfy({ $0.validationError == nil }) else { return nil }
        original = cues
        self.loop = loop
        randomState = seed
        self.cues = shuffled(cues)
        nextLap = loop ? shuffled(cues) : []
        index = 0
        lap = 0
        phase = .running
        anchor(at: now)
        return current
    }

    public mutating func pause(at now: Double) {
        guard phase == .running else { return }
        transport.pause(at: now)
        phase = .paused
    }

    public mutating func resume(at now: Double) {
        guard phase == .paused, now.isFinite else { return }
        transport.start(at: now)
        phase = .running
    }

    public mutating func stop() {
        phase = .idle
        transport.reset()
        index = 0
        cues = []
        nextLap = []
    }

    public func remaining(at now: Double) -> Double? {
        current?.durationSeconds.map { max(0, $0 - transport.elapsed(at: now)) }
    }

    /// Timestamped end events from a previous cue cannot advance a new cue.
    public mutating func tick(at now: Double, mediaEndedAt: Double? = nil) -> RundownCue? {
        guard phase == .running, now.isFinite, let cue = current else { return nil }
        let timedOut = cue.durationSeconds.map { transport.elapsed(at: now) >= $0 } ?? false
        let mediaEnded = cue.advanceOnMediaEnd && (mediaEndedAt.map { $0 > cueStartedAt && $0 <= now } ?? false)
        guard timedOut || mediaEnded else { return nil }
        return skip(at: now)
    }

    public mutating func skip(at now: Double) -> RundownCue? {
        guard (phase == .running || phase == .paused), now.isFinite else { return nil }
        index += 1
        if index >= cues.count {
            guard loop else { phase = .finished; transport.reset(); return nil }
            index = 0
            lap += 1
            cues = nextLap
            nextLap = shuffled(original)
        }
        anchor(at: now)
        if phase == .paused { transport.pause(at: now) }
        return current
    }

    private mutating func anchor(at now: Double) {
        cueStartedAt = now
        transport.reset()
        transport.start(at: now)
    }

    private mutating func shuffled(_ input: [RundownCue]) -> [RundownCue] {
        var result = input
        let groups = Dictionary(grouping: input.indices.filter { !input[$0].randomGroup.isEmpty },
                                by: { input[$0].randomGroup })
        for name in groups.keys.sorted() {
            let indices = groups[name]!
            var group = indices.map { input[$0] }
            guard group.count > 1 else { continue }
            for i in stride(from: group.count - 1, through: 1, by: -1) {
                randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
                group.swapAt(i, Int(randomState % UInt64(i + 1)))
            }
            for (position, index) in indices.enumerated() { result[index] = group[position] }
        }
        return result
    }
}
