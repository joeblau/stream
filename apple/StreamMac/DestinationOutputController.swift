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

    private struct Runtime {
        var generation: UUID
        var publisher: any Publisher
        var video: DestinationVideoMailbox
        var startTask: Task<Void, Never>
        var eventTask: Task<Void, Never>
    }
    private var runtimes: [UUID: Runtime] = [:]
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
        guard !(states[id]?.isActive ?? false) else { return }
        guard activeCount < 10 else { states[id] = .failed("Ten destinations are already active."); changed(); return }
        let generation = UUID()
        let publisher = factory(destination.transport)
        let mailbox = DestinationVideoMailbox(publisher: publisher)
        names[id] = destination.name
        states[id] = .connecting
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
        runtimes[id] = Runtime(generation: generation, publisher: publisher, video: mailbox,
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
            states[id] = .idle
            changed()
            return
        }
        states[id] = .stopping
        fanout.remove(id: id)
        runtime.startTask.cancel()
        runtime.eventTask.cancel()
        runtime.video.stop()
        changed()
        Task { [weak self] in
            await runtime.publisher.stop()
            // A fresh session may already own this ID. Never stop that session.
            guard let self, self.runtimes[id] == nil, self.states[id] == .stopping else { return }
            self.states[id] = .idle
            self.changed()
        }
    }

    func stopAll() { for id in Array(states.keys) { stop(id) } }

    func statsSnapshot() async -> LiveStats? {
        // HUD compatibility: the first acknowledged output, each row carries
        // its own state. No failed endpoint can block these bounded media queues.
        guard let id = states.first(where: { $0.value.isLive })?.key,
              let runtime = runtimes[id] else { return nil }
        return await runtime.publisher.statsSnapshot()
    }

    private func handle(_ event: PublisherEvent, id: UUID, generation: UUID) {
        guard runtimes[id]?.generation == generation else { return }
        switch event {
        case .connecting:
            if case .reconnecting = states[id] {} else { states[id] = .connecting }
        case .published: states[id] = .live
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
    init(publisher: any Publisher) {
        let (stream, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(2))
        self.continuation = continuation
        consumer = Task {
            for await sample in stream {
                if Task.isCancelled { break }
                await publisher.appendVideo(sample)
            }
        }
    }
    func enqueue(_ sample: CMSampleBuffer) { continuation.yield(sample) }
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
