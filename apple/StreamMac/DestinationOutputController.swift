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
    let rawVideoResourceWorkspaceID: UUID
    var frameDelivery: DestinationFrameDeliveryAdapter
    var startIsCurrent: (StreamDestination) -> Bool = { _ in true }
    var stateDidChange: (() -> Void)?
    private(set) var acknowledgedStarts: [UUID: Date] = [:]
    /// Retain the most recent actual start for each output, including stopped
    /// sessions whose remote event may still be live. Never read edited drafts
    /// or infer a remote end from a local stop/failure.
    private var recoveryStarts: [UUID: SessionRecoveryRemoteEvent] = [:]
    var recoveryRemoteEvents: [SessionRecoveryRemoteEvent] {
        recoveryStarts.values.sorted { $0.outputID.uuidString < $1.outputID.uuidString }
    }
    /// Rehearsal disables publisher creation at the output boundary as well as
    /// the command/UI entry points, so no public transport can be started.
    var isPublishingAllowed = true
    /// Explicit fixed-profile opt-in; default retains the existing adaptive,
    /// separate publisher encoders. Only H.264/AAC adapters participate.
    var sharedEncodingEnabled = false
    /// Taken compositor cadence. Unknown or requested higher rates use the
    /// existing separate publisher path rather than claiming generated frames.
    /// Raw publishers also receive this explicit pre-cadenced input contract.
    var sharedSourceFrameRate: Int?
    private var encoderGroups: [DestinationSharedEncoderKey: DestinationSharedEncoder] = [:]
    private var encoderIngresses: [UUID: DestinationVideoIngress] = [:]
    private var finishingEncoderGroups: [UUID: DestinationSharedEncoder] = [:]
    /// Actual active or finalizing groups plus separate publisher sessions.
    var encoderSessionCount: Int {
        encoderGroups.count + finishingEncoderGroups.count + runtimes.values.filter { $0.encoderGroup == nil }.count
            + finalizingRawPublishers.count
    }

    private struct Runtime {
        var generation: UUID
        var destination: StreamDestination
        var publisher: any Publisher
        var video: DestinationVideoMailbox
        var startTask: Task<Void, Never>
        var eventTask: Task<Void, Never>
        var canvas: OutputCanvas
        var encoderGroup: DestinationSharedEncoder?
        var encoded: DestinationEncodedMailbox?
        var ingress: DestinationVideoIngress
    }
    private var runtimes: [UUID: Runtime] = [:]
    private var pendingStops: [UUID: (generation: UUID, task: Task<Void, Never>)] = [:]
    // A failed target can retry under the same stable ID while its previous
    // publisher still drains. Count by session generation, never destination ID.
    private var finalizingRawPublishers: Set<UUID> = []
    private var finishedStops: [UUID: LocalStopResult] = [:]
    private var completedStopOrder: [UUID] = []
    var usesSecondaryCanvas: Bool { runtimes.values.map(\.canvas).contains(.secondary) }

    private let factory: (StreamCore.StreamProtocol) -> any Publisher
    private let sharedEncoderPrefersHardware: Bool

    init(factory: @escaping (StreamCore.StreamProtocol) -> any Publisher, sharedEncoderPrefersHardware: Bool = true,
         workspaceID: UUID = UUID()) {
        rawVideoResourceWorkspaceID = workspaceID
        frameDelivery = .standalone(fanout: fanout)
        self.factory = factory
        self.sharedEncoderPrefersHardware = sharedEncoderPrefersHardware
    }

    func additionalEncoderSessions(destination: StreamDestination, settings: StreamSettings) -> Int {
        guard sharedEncodingEnabled, let sourceFPS = sharedSourceFrameRate,
              let key = DestinationSharedEncoderKey(destination: destination, settings: settings, sourceFrameRate: sourceFPS),
              encoderGroups[key] != nil else { return 1 }
        return 0
    }
    deinit {
        for runtime in runtimes.values { runtime.ingress.close(); runtime.video.stop(); runtime.encoded?.stop() }
        for ingress in encoderIngresses.values { ingress.close() }
        for group in encoderGroups.values { group.stop() }
        for group in finishingEncoderGroups.values { group.stop() }
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

    struct VideoStartInput {
        let destination: StreamDestination
        let settings: StreamSettings
        let sourceSize: CGSize?
    }
    private struct PreparedVideoStart {
        let input: VideoStartInput
        let generation: UUID
        let groupID: UUID
        let key: DestinationSharedEncoderKey?
        let usesExistingIngress: Bool
        let sourceResources: DestinationSourceVideoResources?
        let receipt: RawVideoResourceReceipt
        let bank: RawVideoResourceBank
    }
    private var preparedVideoStarts: [UUID: PreparedVideoStart]?
    private var usedPreparedVideoBanks: Set<UUID> = []

    /// GoLive admits all immediate manual outputs atomically before any factory.
    /// Managed targets still consume their own one-use review at their later
    /// synchronous publish boundary. The body cannot suspend or change claims.
    @discardableResult
    func withPreparedVideoResources(_ inputs: [VideoStartInput], body: () -> Void) -> Bool {
        guard !inputs.isEmpty else { body(); return true }
        guard preparedVideoStarts == nil else { return false }
        let prepared: [UUID: PreparedVideoStart]
        do { prepared = try prepareVideoStarts(inputs) }
        catch {
            let message = (error as? RawVideoResourceFailure)?.localizedDescription ?? "The destinations' video resources could not be admitted."
            for input in inputs { recordFailure(input.destination, message: message) }
            return false
        }
        preparedVideoStarts = prepared; usedPreparedVideoBanks.removeAll()
        defer {
            for plan in prepared.values where !usedPreparedVideoBanks.contains(plan.bank.id) {
                RawVideoResourceCoordinator.shared.rollback(plan.receipt)
            }
            preparedVideoStarts = nil; usedPreparedVideoBanks.removeAll()
        }
        body()
        return true
    }

    private func prepareVideoStarts(_ inputs: [VideoStartInput]) throws -> [UUID: PreparedVideoStart] {
        guard inputs.count <= 10, Set(inputs.map { $0.destination.id }).count == inputs.count else { throw RawVideoResourceFailure.invalidRequest }
        var groupIDs = encoderGroups.mapValues(\.id)
        var claims: [(VideoStartInput, UUID, UUID, DestinationSharedEncoderKey?, RawVideoResourceRequest)] = []
        for input in inputs {
            let destination = input.destination, settings = input.settings
            let generation = UUID()
            let key = sharedEncodingEnabled ? sharedSourceFrameRate.flatMap {
                DestinationSharedEncoderKey(destination: destination, settings: settings, sourceFrameRate: $0)
            } : nil
            let groupID: UUID
            if let key {
                groupID = groupIDs[key] ?? UUID(); groupIDs[key] = groupID
            } else { groupID = UUID() }
            let canvas = destination.canvas ?? .program
            let domain = StableFrameDomainID(workspace: rawVideoResourceWorkspaceID,
                kind: key == nil ? .rawPublisher : .sharedEncoder,
                outputID: key?.resourceDomainID ?? destination.id.uuidString,
                plane: canvas == .secondary ? .secondary : .program)
            let size = key.map { CGSize(width: $0.width, height: $0.height) } ?? input.sourceSize ?? settings.outputProfile.canvasSize
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= 4096, size.height <= 4096 else { throw RawVideoResourceFailure.invalidRequest }
            let request = RawVideoResourceRequest(domain: domain,
                descriptor: .init(width: Int(size.width), height: Int(size.height), capacity: 6),
                sessionGeneration: key == nil ? generation : groupID)
            claims.append((input, generation, groupID, key, request))
        }
        var sourceRequests: [OutputCanvas: RawVideoResourceRequest] = [:]
        for input in inputs {
            let canvas = input.destination.canvas ?? .program
            let size = input.sourceSize ?? input.settings.outputProfile.canvasSize
            if let request = try frameDelivery.sourceRequest(size, canvas) {
                if let existing = sourceRequests[canvas], existing != request { throw RawVideoResourceFailure.sessionConflict }
                sourceRequests[canvas] = request
            }
        }
        let receipt = try RawVideoResourceCoordinator.shared.reserveBatch(claims.map { $0.4 } + Array(sourceRequests.values))
        var result: [UUID: PreparedVideoStart] = [:]
        var children: [StableFrameDomainID: RawVideoResourceReceipt] = [:]
        var sources: [OutputCanvas: DestinationSourceVideoResources] = [:]
        var completed = false
        defer {
            if !completed {
                for child in children.values { RawVideoResourceCoordinator.shared.rollback(child) }
                RawVideoResourceCoordinator.shared.rollback(receipt)
            }
        }
        for (canvas, request) in sourceRequests {
            guard let bank = receipt.bank(for: request.domain) else { throw RawVideoResourceFailure.unknownReservation }
            let child = try receipt.selecting(domain: request.domain)
            children[request.domain] = child
            sources[canvas] = .init(bank: bank, receipt: child)
        }
        for (input, generation, groupID, key, request) in claims {
            guard let bank = receipt.bank(for: request.domain) else {
                RawVideoResourceCoordinator.shared.rollback(receipt)
                throw RawVideoResourceFailure.unknownReservation
            }
            let child: RawVideoResourceReceipt
            if let existing = children[request.domain] { child = existing }
            else {
                child = try receipt.selecting(domain: request.domain)
                children[request.domain] = child
            }
            result[input.destination.id] = .init(input: input, generation: generation, groupID: groupID, key: key,
                usesExistingIngress: key.flatMap { encoderGroups[$0] } != nil,
                sourceResources: sources[input.destination.canvas ?? .program], receipt: child, bank: bank)
        }
        completed = true
        return result
    }

    @discardableResult
    func start(_ destination: StreamDestination, settings: StreamSettings, sourceSize: CGSize? = nil,
               authorization: @escaping @MainActor (UUID) -> Bool = { _ in true }) -> Bool {
        let id = destination.id
        guard isPublishingAllowed, startIsCurrent(destination) else { return false }
        guard !(states[id]?.isActive ?? false) else { return false }
        guard activeCount < 10 else { states[id] = .failed("Ten destinations are already active."); changed(); return false }
        let prepared: PreparedVideoStart
        do {
            if let batch = preparedVideoStarts {
                guard let plan = batch[id], plan.input.destination == destination,
                      plan.input.settings == settings, plan.input.sourceSize == sourceSize else {
                    throw RawVideoResourceFailure.sessionConflict
                }
                prepared = plan
            } else {
                guard let plan = try prepareVideoStarts([.init(destination: destination, settings: settings, sourceSize: sourceSize)])[id] else {
                    throw RawVideoResourceFailure.unknownReservation
                }
                prepared = plan
            }
        } catch {
            recordFailure(destination, message: (error as? RawVideoResourceFailure)?.localizedDescription ?? "The destination's video resources could not be admitted.")
            return false
        }
        let generation = prepared.generation, groupID = prepared.groupID, key = prepared.key
        let receipt = prepared.receipt, bank = prepared.bank
        let existingGroup = key.flatMap { encoderGroups[$0] }
        guard existingGroup == nil || existingGroup?.id == groupID else {
            if preparedVideoStarts == nil { RawVideoResourceCoordinator.shared.rollback(receipt) }
            recordFailure(destination, message: RawVideoResourceFailure.sessionConflict.localizedDescription)
            return false
        }
        let canvas = destination.canvas ?? .program
        // No factory or transport side effect occurs until the whole resource
        // request has passed synchronous actual-storage admission.
        let publisher = factory(destination.transport)
        if key != nil, !publisher.supportsSharedH264AAC {
            if preparedVideoStarts == nil { RawVideoResourceCoordinator.shared.rollback(receipt) }
            recordFailure(destination, message: "This publisher does not support the selected shared encoder input.")
            return false
        }
        let mailbox = DestinationVideoMailbox(publisher: publisher)
        var encoderGroup: DestinationSharedEncoder?
        var encoded: DestinationEncodedMailbox?
        let ingress: DestinationVideoIngress
        if let key {
            let group: DestinationSharedEncoder
            if let existingGroup {
                group = existingGroup
                if prepared.usesExistingIngress { RawVideoResourceCoordinator.shared.rollback(receipt) }
            }
            else {
                group = DestinationSharedEncoder(key: key, bank: bank, id: groupID, prefersHardwareEncoder: sharedEncoderPrefersHardware) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        for (id, runtime) in self.runtimes where runtime.encoderGroup?.id == groupID {
                            self.fail(id: id, message: "The shared H.264/AAC encoder failed. Stop these outputs and review the profile or resource load.")
                        }
                    }
                }
                encoderGroups[key] = group
                encoderIngresses[groupID] = DestinationVideoIngress(bank: bank, receipt: receipt, canvas: canvas,
                    transfer: .aspectFitBGRA, sourceResources: prepared.sourceResources, adapter: frameDelivery) { [group, weak fanout] frame in
                        fanout?.recordVideoClock(frame.sampleBuffer, canvas: canvas)
                        group.enqueuePreparedVideo(frame.sampleBuffer)
                    }
            }
            guard let sharedIngress = encoderIngresses[groupID] else {
                if preparedVideoStarts == nil { RawVideoResourceCoordinator.shared.rollback(receipt) }
                recordFailure(destination, message: "The shared encoder's video ingress is unavailable.")
                return false
            }
            ingress = sharedIngress; encoderGroup = group
            let sink = DestinationEncodedMailbox(publisher: publisher) { [weak group] in group?.requestKeyframe() }
            group.add(sink, id: id); encoded = sink
        } else {
            ingress = DestinationVideoIngress(bank: bank, receipt: receipt, canvas: canvas,
                transfer: .copyBGRA, sourceResources: prepared.sourceResources, adapter: frameDelivery) { [mailbox, weak fanout] frame in
                    fanout?.recordVideoClock(frame.sampleBuffer, canvas: canvas)
                    mailbox.enqueue(frame.sampleBuffer)
                }
        }
        let usesEncoded = encoderGroup != nil
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
        let programSourceFrameRate = sharedSourceFrameRate
        let startTask = Task { [weak self, encoderGroup, ingress] in
            do {
                if let encoderGroup { try await encoderGroup.prepare() }
                try Task.checkCancellation()
                try await ingress.install()
                try Task.checkCancellation()
                guard let self, self.startStillCurrent(id: id, generation: generation, destination: destination) else { return }
                if usesEncoded, !(await publisher.configureEncodedInput()) { throw NSError(domain: "SharedEncoder", code: 1) }
                try Task.checkCancellation()
                guard self.startStillCurrent(id: id, generation: generation, destination: destination) else { return }
                if !usesEncoded, let programSourceFrameRate { await publisher.configureProgramVideo(sourceFrameRate: programSourceFrameRate) }
                try Task.checkCancellation()
                guard self.startStillCurrent(id: id, generation: generation, destination: destination) else { return }
                // Managed review is consumed synchronously at handoff, while
                // local resource preparation may suspend. Recheck captured
                // startup authority once, at the final pre-start boundary.
                // Already-started outputs are not revoked by this closure.
                guard authorization(generation) else { self.stop(id); return }
                try await publisher.start(settings)
                try Task.checkCancellation()
                guard self.startStillCurrent(id: id, generation: generation, destination: destination) else { return }
                let size = settings.outputProfile.canvasSize
                await publisher.setOutputSize(size, nativeShortEdge: min(settings.outputProfile.canvasWidth, settings.outputProfile.canvasHeight))
            } catch {
                guard let self, self.runtimes[id]?.generation == generation else { return }
                if error is CancellationError { self.stop(id); return }
                let message = (error as? RawVideoResourceFailure)?.localizedDescription
                    ?? "The destination could not start. Check its endpoint, credentials, video resources and ingest availability."
                self.fail(id: id, message: message)
            }
        }
        runtimes[id] = Runtime(generation: generation, destination: destination, publisher: publisher, video: mailbox,
                               startTask: startTask, eventTask: eventTask, canvas: canvas, encoderGroup: encoderGroup, encoded: encoded, ingress: ingress)
        if preparedVideoStarts != nil { usedPreparedVideoBanks.insert(bank.id) }
        let binding = destination.providerBinding.flatMap {
            RecoveryEventIdentity.validID($0.channelID) && ($0.eventID.map(RecoveryEventIdentity.validID) ?? true) ? $0 : nil
        }
        recoveryStarts[id] = .init(outputID: id, eventID: binding?.eventID, provider: binding?.provider,
            channelID: binding?.channelID, publisherSessionID: generation, capturedAt: Date())
        while recoveryStarts.count > 10 {
            // Active sessions always retain their identity. Only stopped prior
            // outputs are evicted from this bounded recent-session inventory.
            guard let oldest = recoveryStarts.values.filter({ runtimes[$0.outputID] == nil })
                .min(by: { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }) else { break }
            recoveryStarts[oldest.outputID] = nil
        }
        fanout.add(id: id, publisher: publisher, video: mailbox, canvas: destination.canvas ?? .program, group: encoderGroup)
        changed()
        return true
    }

    private func startStillCurrent(id: UUID, generation: UUID, destination: StreamDestination) -> Bool {
        guard runtimes[id]?.generation == generation else { return false }
        guard isPublishingAllowed, startIsCurrent(destination) else { stop(id); return false }
        return true
    }

    #if STREAM_NATIVE_VALIDATION
    /// Deliberate defense-in-depth codec negatives only. Ordinary inputs MUST
    /// cross the sealed broker; an audio sample is rejected there first.
    func validationEnqueuePreparedVideo(_ sample: CMSampleBuffer, destinationID: UUID) {
        runtimes[destinationID]?.encoderGroup?.enqueuePreparedVideo(sample)
    }
    #endif

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
        if runtime.encoderGroup == nil { runtime.ingress.close() }
        else if let group = runtime.encoderGroup,
                !runtimes.values.contains(where: { $0.encoderGroup === group }) {
            encoderIngresses.removeValue(forKey: group.id)?.close()
        }
        if runtime.encoderGroup == nil { finalizingRawPublishers.insert(runtime.generation) }
        changed()
        let task = Task { [weak self] in
            let mediaDrained: Bool
            if runtime.encoderGroup != nil {
                mediaDrained = await self?.finishEncodedStop(runtime, id: id) ?? false
                runtime.encoded?.stop()
            } else { mediaDrained = true }
            await runtime.publisher.stop()
            guard let self else { return }
            self.finalizingRawPublishers.remove(runtime.generation)
            // A bounded mailbox timeout still closes the transport, but must
            // not fabricate a completed media-drain receipt.
            self.finishedStops[runtime.generation] = mediaDrained ? .stopped : .unconfirmed
            self.completedStopOrder.append(runtime.generation)
            while self.completedStopOrder.count > 128 { self.finishedStops.removeValue(forKey: self.completedStopOrder.removeFirst()) }
            let ownsStop = self.pendingStops[id]?.generation == runtime.generation
            if ownsStop { self.pendingStops[id] = nil }
            // A fresh session or teardown may already own this ID.
            guard ownsStop, self.runtimes[id] == nil, self.states[id] == .stopping else { self.changed(); return }
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
        if let receipt = finishedStops[token] { return receipt }
        if let current = runtimes[id]?.generation, current != token { return .superseded }
        return .unconfirmed
    }
    func stopIfCurrent(_ id: UUID, token: UUID, timeout: Double = 10) async -> LocalStopResult {
        if let receipt = finishedStops[token] { return receipt }
        if runtimes[id]?.generation == token { stop(id) }
        else if pendingStops[id]?.generation != token { return .superseded }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, min(30, timeout))))
        while ContinuousClock.now < deadline {
            if let receipt = finishedStops[token] { return receipt }
            if let current = runtimes[id]?.generation, current != token { return .superseded }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return .unconfirmed }
        }
        return finishedStops[token] ?? .unconfirmed
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
            let inputClock = await runtime?.publisher.encoderInputClockSnapshot()
            let transfer = await runtime?.ingress.statistics()
            let mailbox: (depth: Int, drops: Int)?
            if let encoded = runtime?.encoded {
                let counters = encoded.statistics(); mailbox = (counters.depth, counters.drops)
            } else { mailbox = runtime?.video.statistics() }
            result.append(.init(id: id.uuidString, state: label, startedAt: acknowledgedStarts[id],
                targetFPS: stats?.frameRate, achievedFPS: stats?.achievedFrameRate,
                bitrate: stats?.bitRate, socketQueueBytes: stats?.queueBytes,
                stalledSeconds: stats?.zeroOutputSeconds, encoderCongestionDrops: stats?.droppedFrames,
                videoQueueDepth: mailbox?.depth ?? 0, videoMailboxDrops: mailbox?.drops ?? 0,
                encoderInputClock: inputClock, sharedEncodedClock: runtime?.encoderGroup?.encodedClock.snapshot(),
                privateVideoTransferDrops: transfer?.drops, privateVideoCapacityDrops: transfer?.privateCapacityDrops,
                privateVideoConversionFailures: transfer?.conversionFailures))
        }
        return result
    }

    private func handle(_ event: PublisherEvent, id: UUID, generation: UUID) {
        guard runtimes[id]?.generation == generation else { return }
        switch event {
        case .connecting:
            if case .reconnecting = states[id] {} else { states[id] = .connecting }
        case .published:
            runtimes[id]?.encoded?.setPublished(true)
            states[id] = .live
            if acknowledgedStarts[id] == nil { acknowledgedStarts[id] = Date() }
        case .reconnecting:
            runtimes[id]?.encoded?.setPublished(false)
            states[id] = .reconnecting(reason: "Connection interrupted; this destination is retrying.")
        case .failed: fail(id: id, message: "This destination failed. Check its endpoint and credentials, then retry."); return
        case .stopped: stop(id); return
        }
        changed()
    }

    private func fail(id: UUID, message: String) {
        acknowledgedStarts[id] = nil
        if let runtime = runtimes.removeValue(forKey: id) {
            fanout.remove(id: id)
            runtime.startTask.cancel()
            runtime.eventTask.cancel()
            runtime.video.stop(); runtime.encoded?.stop(); releaseEncoderGroup(runtime, id: id)
            if runtime.encoderGroup == nil { runtime.ingress.close() }
            if runtime.encoderGroup == nil { finalizingRawPublishers.insert(runtime.generation) }
            Task { [weak self] in
                await runtime.publisher.stop()
                guard let self else { return }
                self.finalizingRawPublishers.remove(runtime.generation); self.changed()
            }
        }
        // Transport NSError descriptions sometimes include credential-bearing
        // URLs. Only a fixed, actionable public message reaches UI/project state.
        states[id] = .failed(message)
        changed()
    }

    private func releaseEncoderGroup(_ runtime: Runtime, id: UUID) {
        guard let group = runtime.encoderGroup else { return }
        group.remove(id)
        guard !runtimes.values.contains(where: { $0.encoderGroup === group }) else { return }
        guard encoderGroups[group.key] === group else { return }
        encoderGroups[group.key] = nil; finishingEncoderGroups[group.id] = group
        encoderIngresses.removeValue(forKey: group.id)?.close()
        group.stop { [weak self, weak group] in
            Task { @MainActor in
                guard let self, let group else { return }
                self.finishingEncoderGroups[group.id] = nil; self.changed()
            }
        }
    }

    private func finishEncodedStop(_ runtime: Runtime, id: UUID) async -> Bool {
        guard let group = runtime.encoderGroup, let mailbox = runtime.encoded else { return true }
        // Decide after the synchronous stop/stopAll call has removed runtimes.
        // Simultaneously ending members then share one real EOS drain, while a
        // single target leaving a live group never resets that group's codec.
        let lastMembers = !runtimes.values.contains(where: { $0.encoderGroup === group })
        if lastMembers, encoderGroups[group.key] === group {
            encoderGroups[group.key] = nil; finishingEncoderGroups[group.id] = group
        }
        let encoderFinished: Bool
        if lastMembers {
            // A sibling stop may already have finished and released the
            // reservation. finish also returns that cached success/failure.
            encoderFinished = await withCheckedContinuation { continuation in
                group.finish { continuation.resume(returning: $0) }
            }
            finishingEncoderGroups[group.id] = nil
        } else {
            group.remove(id)
            encoderFinished = true
        }
        let drained = await mailbox.finish()
        group.remove(id)
        changed()
        return encoderFinished && drained
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
    let programClock = AVClockTelemetry()
    let secondaryClock = AVClockTelemetry()
    private struct Sink { var publisher: any Publisher; var video: DestinationVideoMailbox; var canvas: OutputCanvas; var group: DestinationSharedEncoder? }
    private var lock = os_unfair_lock_s()
    private var sinks: [UUID: Sink] = [:]
    func add(id: UUID, publisher: any Publisher, video: DestinationVideoMailbox, canvas: OutputCanvas = .program, group: DestinationSharedEncoder? = nil) {
        os_unfair_lock_lock(&lock)
        sinks[id] = Sink(publisher: publisher, video: video, canvas: canvas, group: group)
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
    private var lastVideoPTS: [OutputCanvas: CMTime] = [:]
    private let programDelivery = FrameDeliveryBroker()
    private let secondaryDelivery = FrameDeliveryBroker()
    func broker(for canvas: OutputCanvas) -> FrameDeliveryBroker { canvas == .secondary ? secondaryDelivery : programDelivery }
    func recordVideoClock(_ sample: CMSampleBuffer, canvas: OutputCanvas) {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard lastVideoPTS[canvas].map({ CMTimeCompare(pts, $0) > 0 }) ?? true else { return }
        lastVideoPTS[canvas] = pts
        (canvas == .program ? programClock : secondaryClock).record(.video, presentationSeconds: pts.seconds)
    }
    /// Standalone source ingress used by owned publisher fixtures. Shipping
    /// installs the same logical deliveries on the compositor's central broker.
    /// This never forwards an original sample into a publisher or encoder.
    func enqueueVideo(_ sample: CMSampleBuffer, canvas: OutputCanvas = .program) {
        broker(for: canvas).offer(.init(sampleBuffer: sample, presentationTime: sample.presentationTimeStamp,
            frameDuration: sample.duration, sequence: sample.presentationTimeStamp.value))
    }
    func enqueueAudio(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        programClock.record(.audio, presentationSeconds: sample.presentationTimeStamp.seconds, observedHostSeconds: now)
        secondaryClock.record(.audio, presentationSeconds: sample.presentationTimeStamp.seconds, observedHostSeconds: now)
        var visited = Set<UUID>()
        for sink in snapshot() {
            if let group = sink.group { if visited.insert(group.id).inserted { group.enqueueAudio(sample) } }
            else { sink.publisher.enqueueProgram(sample) }
        }
    }
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
    var encoderInputClock: AVClockSnapshot? = nil
    var sharedEncodedClock: AVClockSnapshot? = nil
    var privateVideoTransferDrops: Int? = nil
    var privateVideoCapacityDrops: Int? = nil
    var privateVideoConversionFailures: Int? = nil
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
