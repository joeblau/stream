import Combine
import CoreMedia
import Foundation
import StreamCore
import os.lock

/// Independent supervised sessions. Every destination owns a bounded media
/// mailbox and its own publisher actor; no transport await occurs on fan-out.
@MainActor
final class DestinationOutputController: ObservableObject {
    @Published private(set) var states: [UUID: StreamSessionState] = [:]
    @Published private(set) var names: [UUID: String] = [:]
    let fanout = DestinationMediaFanout()
    var stateDidChange: (() -> Void)?
    private(set) var acknowledgedStarts: [UUID: Date] = [:]
    /// Rehearsal disables publisher creation at the output boundary as well as
    /// the command/UI entry points, so no public transport can be started.
    var isPublishingAllowed = true

    private struct Runtime {
        var generation: UUID
        var destination: StreamDestination
        var publisher: any Publisher
        var video: DestinationVideoMailbox
        var startTask: Task<Void, Never>
        var eventTask: Task<Void, Never>
    }
    private var runtimes: [UUID: Runtime] = [:]
    private var pendingStops: [UUID: (generation: UUID, task: Task<Void, Never>)] = [:]
    private var completedStops: Set<UUID> = []
    private var completedStopOrder: [UUID] = []
    private let factory: (StreamCore.StreamProtocol) -> any Publisher

    init(factory: @escaping (StreamCore.StreamProtocol) -> any Publisher) {
        self.factory = factory
    }

    var aggregateState: StreamSessionState {
        let values = Array(states.values)
        if values.contains(.live) { return .live }
        if let recovering = values.first(where: { if case .reconnecting = $0 { return true }; return false }) {
            return recovering
        }
        if values.contains(.connecting) { return .connecting }
        if values.contains(.stopping) { return .stopping }
        if let failed = values.first(where: { if case .failed = $0 { return true }; return false }) { return failed }
        return .idle
    }
    var liveCount: Int { states.values.filter(\.isLive).count }
    var activeCount: Int { states.values.filter(\.isActive).count }
    var partialSuccess: Bool { liveCount > 0 && liveCount < states.values.filter { $0 != .idle }.count }

    func start(_ destination: StreamDestination, settings: StreamSettings) {
        let id = destination.id
        guard isPublishingAllowed else { return }
        guard !(states[id]?.isActive ?? false) else { return }
        guard activeCount < 10 else { states[id] = .failed("Ten destinations are already active."); changed(); return }
        let generation = UUID()
        let publisher = factory(destination.transport)
        let mailbox = DestinationVideoMailbox(publisher: publisher)
        names[id] = destination.name
        states[id] = .connecting
        acknowledgedStarts[id] = nil
        // Attach the lifecycle consumer BEFORE start so early connect failures
        // cannot be missed. Generation checks discard callbacks from old retries.
        let eventTask = Task { [weak self] in
            for await event in publisher.events {
                guard let self, self.runtimes[id]?.generation == generation else { return }
                self.handle(event, id: id, generation: generation)
            }
        }
        let startTask = Task { [weak self] in
            do {
                try await publisher.start(settings)
                guard !Task.isCancelled else { return }
                let size = settings.outputProfile.canvasSize
                await publisher.setOutputSize(size, nativeShortEdge: min(settings.outputProfile.canvasWidth, settings.outputProfile.canvasHeight))
            } catch {
                guard let self, self.runtimes[id]?.generation == generation else { return }
                self.fail(id: id, message: "The destination could not connect. Check its endpoint, credentials and ingest availability.")
            }
        }
        runtimes[id] = Runtime(generation: generation, destination: destination, publisher: publisher, video: mailbox,
                               startTask: startTask, eventTask: eventTask)
        fanout.add(id: id, publisher: publisher, video: mailbox)
        changed()
    }

    func recordFailure(_ destination: StreamDestination, message: String) {
        guard !(states[destination.id]?.isActive ?? false) else { return }
        names[destination.id] = destination.name
        states[destination.id] = .failed(message)
        changed()
    }

    func stop(_ id: UUID) {
        guard let runtime = runtimes.removeValue(forKey: id) else {
            // Repeated disconnect requests must not fabricate an idle receipt
            // while the original publisher is still finishing its stop.
            if pendingStops[id] != nil { return }
            states[id] = .idle
            changed()
            return
        }
        states[id] = .stopping
        acknowledgedStarts[id] = nil
        fanout.remove(id: id)
        runtime.startTask.cancel()
        runtime.eventTask.cancel()
        runtime.video.stop()
        changed()
        let task = Task { [weak self] in
            await runtime.publisher.stop()
            guard let self else { return }
            self.completedStops.insert(runtime.generation); self.completedStopOrder.append(runtime.generation)
            while self.completedStopOrder.count > 128 { self.completedStops.remove(self.completedStopOrder.removeFirst()) }
            let ownsStop = self.pendingStops[id]?.generation == runtime.generation
            if ownsStop { self.pendingStops[id] = nil }
            // A fresh session or teardown may already own this ID.
            guard ownsStop, self.runtimes[id] == nil, self.states[id] == .stopping else { return }
            self.states[id] = .idle
            self.changed()
        }
        pendingStops[id] = (runtime.generation, task)
    }

    struct EndingSession: Sendable { let destination: StreamDestination; let token: UUID }
    enum LocalStopResult: String, Sendable { case stopped, superseded, unconfirmed }
    /// The routing snapshot belongs to the session that actually started;
    /// applying edits for a future start cannot end the wrong remote event.
    var endingSessions: [EndingSession] { runtimes.values.map { .init(destination: $0.destination, token: $0.generation) } }
    func sessionToken(_ id: UUID) -> UUID? { runtimes[id]?.generation }
    func stopReceipt(_ id: UUID, token: UUID) -> LocalStopResult {
        if completedStops.contains(token) { return .stopped }
        if let current = runtimes[id]?.generation, current != token { return .superseded }
        return .unconfirmed
    }
    func stopIfCurrent(_ id: UUID, token: UUID, timeout: Double = 10) async -> LocalStopResult {
        if completedStops.contains(token) { return .stopped }
        if runtimes[id]?.generation == token { stop(id) }
        else if pendingStops[id]?.generation != token { return .superseded }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, min(30, timeout))))
        while ContinuousClock.now < deadline {
            if completedStops.contains(token) { return .stopped }
            if let current = runtimes[id]?.generation, current != token { return .superseded }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return .unconfirmed }
        }
        return completedStops.contains(token) ? .stopped : .unconfirmed
    }

    func stopAll() { for id in Array(states.keys) { stop(id) } }

    func statsSnapshot() async -> LiveStats? {
        // HUD compatibility: the first acknowledged output, each row carries
        // its own state. No failed endpoint can block these bounded media queues.
        guard let id = states.first(where: { $0.value.isLive })?.key,
              let runtime = runtimes[id] else { return nil }
        return await runtime.publisher.statsSnapshot()
    }

    func diagnosticsSnapshot() async -> [DestinationDiagnosticSnapshot] {
        var result: [DestinationDiagnosticSnapshot] = []
        for id in states.keys.sorted(by: { $0.uuidString < $1.uuidString }).prefix(64) {
            let state = states[id] ?? .idle
            let label: String = switch state {
            case .idle: "idle"; case .connecting: "connecting"; case .live: "live"
            case .reconnecting: "reconnecting"; case .stopping: "stopping"; case .failed: "failed"
            }
            let runtime = runtimes[id]
            let stats = await runtime?.publisher.statsSnapshot()
            let mailbox = runtime?.video.statistics()
            result.append(.init(id: id.uuidString, state: label, startedAt: acknowledgedStarts[id],
                targetFPS: stats?.frameRate, achievedFPS: stats?.achievedFrameRate,
                bitrate: stats?.bitRate, socketQueueBytes: stats?.queueBytes,
                stalledSeconds: stats?.zeroOutputSeconds, encoderCongestionDrops: stats?.droppedFrames,
                videoQueueDepth: mailbox?.depth ?? 0, videoMailboxDrops: mailbox?.drops ?? 0))
        }
        return result
    }

    private func handle(_ event: PublisherEvent, id: UUID, generation: UUID) {
        guard runtimes[id]?.generation == generation else { return }
        switch event {
        case .connecting:
            if case .reconnecting = states[id] {} else { states[id] = .connecting }
        case .published:
            states[id] = .live
            if acknowledgedStarts[id] == nil { acknowledgedStarts[id] = Date() }
        case .reconnecting: states[id] = .reconnecting(reason: "Connection interrupted; this destination is retrying.")
        case .failed: fail(id: id, message: "This destination failed. Check its endpoint and credentials, then retry."); return
        case .stopped: stop(id); return
        }
        changed()
    }

    private func fail(id: UUID, message: String) {
        if let runtime = runtimes.removeValue(forKey: id) {
            fanout.remove(id: id)
            runtime.startTask.cancel()
            runtime.eventTask.cancel()
            runtime.video.stop()
            Task { await runtime.publisher.stop() }
        }
        // Transport NSError descriptions sometimes include credential-bearing
        // URLs. Only a fixed, actionable public message reaches UI/project state.
        states[id] = .failed(message)
        changed()
    }

    private func changed() { stateDidChange?() }
}

/// One ordered consumer per destination, buffering the newest two frames. A
/// publisher waiting on a slow network sheds only its own frames.
final class DestinationVideoMailbox: @unchecked Sendable {
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    private let consumer: Task<Void, Never>
    private let counters: DestinationMailboxCounters
    init(publisher: any Publisher) {
        let (stream, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(2))
        self.continuation = continuation
        let counters = DestinationMailboxCounters()
        self.counters = counters
        consumer = Task {
            for await sample in stream {
                if Task.isCancelled { break }
                counters.dequeued()
                await publisher.appendVideo(sample)
            }
        }
    }
    func enqueue(_ sample: CMSampleBuffer) { counters.enqueue(sample, continuation: continuation) }
    func statistics() -> (depth: Int, drops: Int) { counters.snapshot() }
    func stop() { continuation.finish(); consumer.cancel() }
}

/// Capture-thread fanout snapshots sinks under a lock and releases it BEFORE
/// ingress. Both ingress methods are synchronous bounded enqueues.
final class DestinationMediaFanout: @unchecked Sendable {
    private struct Sink { var publisher: any Publisher; var video: DestinationVideoMailbox }
    private var lock = os_unfair_lock_s()
    private var sinks: [UUID: Sink] = [:]
    func add(id: UUID, publisher: any Publisher, video: DestinationVideoMailbox) {
        os_unfair_lock_lock(&lock)
        sinks[id] = Sink(publisher: publisher, video: video)
        os_unfair_lock_unlock(&lock)
    }
    func remove(id: UUID) {
        os_unfair_lock_lock(&lock)
        sinks[id] = nil
        os_unfair_lock_unlock(&lock)
    }
    private func snapshot() -> [Sink] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(sinks.values)
    }
    func enqueueVideo(_ sample: CMSampleBuffer) { for sink in snapshot() { sink.video.enqueue(sample) } }
    func enqueueAudio(_ sample: CMSampleBuffer) { for sink in snapshot() { sink.publisher.enqueueProgram(sample) } }
}

struct DestinationDiagnosticSnapshot: Codable, Sendable {
    var id: String
    var state: String
    var startedAt: Date?
    var targetFPS: Int?
    var achievedFPS: Int?
    var bitrate: Int?
    var socketQueueBytes: Int?
    var stalledSeconds: Int?
    var encoderCongestionDrops: Int?
    var videoQueueDepth: Int
    var videoMailboxDrops: Int
}

private final class DestinationMailboxCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0
    private var drops = 0
    func enqueue(_ sample: CMSampleBuffer, continuation: AsyncStream<CMSampleBuffer>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        switch continuation.yield(sample) {
        case .enqueued(let remaining): depth = max(0, 2 - remaining)
        case .dropped: depth = 2; drops += 1
        case .terminated: depth = 0
        @unknown default: break
        }
    }
    func dequeued() { lock.lock(); depth = max(0, depth - 1); lock.unlock() }
    func snapshot() -> (depth: Int, drops: Int) { lock.lock(); defer { lock.unlock() }; return (depth, drops) }
}
