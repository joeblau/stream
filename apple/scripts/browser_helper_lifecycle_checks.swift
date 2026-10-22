import CoreMedia
import Foundation

/// Command-only qualification of the shipping ACK/revision state machine.
/// The inert driver never launches SCK, renders PCM or opens an audio device.
@MainActor enum BrowserHelperLifecycleChecks {
    @MainActor private final class Driver: BrowserWidgetAudioDriver {
        var isCapturing = false
        var starts = 0
        var beforeStart: (@MainActor () async -> Void)?
        var beforeStop: (@MainActor () async -> Void)?
        var stops = 0
        var invalidations = 0
        let requiresScreenCaptureAccess = false
        var onFailure: (@MainActor (String) -> Void)?
        func start(helperPID: Int32) async throws { precondition(helperPID == 42); await beforeStart?(); starts += 1; isCapturing = true }
        func invalidateInput() { invalidations += 1 }
        func stop() async { await beforeStop?(); isCapturing = false; stops += 1 }
    }
    @MainActor private final class Transport: BrowserWidgetHelperTransport {
        let pid: Int32 = 42
        var rejectedAction: BrowserWidgetAudioCommand.Action?
        var onSend: (@MainActor (BrowserWidgetAudioCommand) -> Void)?
        var commands: [BrowserWidgetAudioCommand] = []
        var closed = false
        var closeCount = 0
        var onClose: (@MainActor () -> Void)?
        var hasTerminated = false
        var holdStop = false
        var reply: ((BrowserWidgetAudioReply) -> Void)?
        func send(_ value: BrowserWidgetAudioCommand) throws {
            if value.action == rejectedAction { throw BrowserWidgetHelperSession.SessionError.unavailable }
            commands.append(value)
            onSend?(value)
            if value.action == .stop && holdStop { return }
            let state: BrowserWidgetAudioReply.State
            switch value.action {
            case .load, .resume: state = .loaded
            case .suspend: state = .suspended
            case .stop: state = .stopped
            default: return
            }
            reply?(.init(state: state, widgetID: value.widgetID, helperPID: pid,
                         requestID: value.requestID, generation: value.generation))
        }
        func close() { onClose?(); closeCount += 1; closed = true }
    }
    @MainActor private final class States {
        var values: [BrowserOverlayLoadState] = []
        var callbacks: BrowserWidgetHelperSession.Callbacks {
            .init(state: { [self] in values.append($0) }, frame: { _, _ in
                preconditionFailure("A command-only fixture must never produce a frame")
            }, snapshotFailed: {})
        }
        var hasFailure: Bool { values.contains { if case .failed = $0 { true } else { false } } }
    }
    @MainActor private final class HeldStart {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        func wait() async {
            entered = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() }
            await withCheckedContinuation { continuation = $0 }
        }
        func untilEntered() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
        func release() { continuation?.resume(); continuation = nil }
    }
    static func run() async throws {
        let path = URL(fileURLWithPath: "/unavailable-owned-browser-fixture.app")
        // Real file staging and session ownership with an inert transport. The
        // old generation's bundle survives a held Stop; stale receipts cannot
        // retire its replacement, and terminate-request is not process exit.
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("stream-local-session-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: root) }
            let source = root.appendingPathComponent("index.html")
            try Data("<html>owned local fixture</html>".utf8).write(to: source)
            let transport = Transport(), driver = Driver(), states = States()
            let session = BrowserWidgetHelperSession(applicationURL: path, mixer: AudioMixEngine(),
                validationAudioDriver: driver, transportForQualification: transport)
            session.validationLocalContainer = root
            transport.reply = { [weak session] in session?.validationReceive($0) }
            let id = UUID(), generation = UUID()
            try await session.loadForQualification(id: id, generation: generation, localSource: source, options: .init(), callbacks: states.callbacks)
            let oldPage = transport.commands.last(where: { $0.action == .load })!.localPage!
            // Keep the injected helper connection owned while this page retires.
            let sibling = UUID()
            try await session.loadForQualification(id: sibling, generation: UUID(), html: "sibling", options: .init(), callbacks: states.callbacks)
            let oldRoot = try BrowserWidgetLocalContent.resolve(oldPage, container: root, widget: id, generation: generation).root
            transport.holdStop = true
            session.release(id)
            let replacement = UUID()
            let load = Task { try await session.loadForQualification(id: id, generation: replacement,
                localSource: source, options: .init(), callbacks: states.callbacks) }
            for _ in 0..<1000 {
                if transport.commands.contains(where: { $0.action == .stop }) { break }
                await Task.yield()
            }
            guard let stop = transport.commands.last(where: { $0.action == .stop }) else { preconditionFailure("Stop was not requested") }
            precondition(fm.fileExists(atPath: oldRoot.path), "Held Stop prematurely deleted old local content")
            precondition(!transport.commands.contains { $0.action == .load && $0.generation == replacement })
            // A wrong generation cannot release this retirement barrier.
            session.validationReceive(.init(state: .stopped, widgetID: id, helperPID: 42,
                requestID: UUID(), generation: replacement))
            precondition(fm.fileExists(atPath: oldRoot.path))
            transport.holdStop = false
            session.validationReceive(.init(state: .stopped, widgetID: id, helperPID: 42,
                requestID: stop.requestID, generation: generation))
            try await load.value
            let fresh = transport.commands.last(where: { $0.action == .load })!.localPage!
            let freshRoot = try BrowserWidgetLocalContent.resolve(fresh, container: root, widget: id, generation: replacement).root
            precondition(!fm.fileExists(atPath: oldRoot.path) && fm.fileExists(atPath: freshRoot.path))
            session.validationReceive(.init(state: .stopped, widgetID: id, helperPID: 42,
                requestID: stop.requestID, generation: generation))
            precondition(fm.fileExists(atPath: freshRoot.path), "Old Stop deleted fresh bundle")
            transport.rejectedAction = .stop
            session.release(id); await session.waitUntilStopped()
            precondition(transport.closed && fm.fileExists(atPath: freshRoot.path), "Termination request was treated as process exit")
            transport.hasTerminated = true
            BrowserWidgetLocalRetirement.retry()
            precondition(!fm.fileExists(atPath: freshRoot.path))
            print("PASS: actual local session stages off-main, holds old files through exact Stop ACK/reload, rejects stale receipt, and quarantines shutdown files until confirmed owned process exit; no helper/capture")
        }
        // Session failure revokes authority immediately, but the exact helper
        // must outlive both a pending capture start and a pending capture stop.
        // Replacement demand stays behind the existing shutdown barrier.
        for holdStart in [true, false] {
            let transport = Transport(), driver = Driver(), states = States(), held = HeldStart()
            let session = BrowserWidgetHelperSession(applicationURL: path, mixer: AudioMixEngine(),
                validationAudioDriver: driver, transportForQualification: transport)
            session.prepareMixerForAudio = { .init(isCurrent: { true }) }
            transport.reply = { [weak session] in session?.validationReceive($0) }
            let id = UUID(), generation = UUID(), lease = BrowserWidgetPageLease(widgetID: id, generation: generation)
            try await session.loadForQualification(id: id, generation: generation, html: "owned-shutdown", options: .init(), callbacks: states.callbacks)
            if holdStart { driver.beforeStart = { await held.wait() } }
            session.setProgramAudioDemand([lease], exclusions: .init(id: UUID(), helperPID: 42, isCurrent: { true }))
            if holdStart { await held.untilEntered() }
            else {
                await session.waitUntilStopped()
                precondition(session.audibleLeases == [lease] && driver.isCapturing)
                driver.beforeStop = { driver.beforeStop = nil; await held.wait() }
            }
            let stopsBeforeFailure = driver.stops, invalidationsBeforeFailure = driver.invalidations
            transport.onClose = {
                precondition(!driver.isCapturing && driver.stops > stopsBeforeFailure,
                             "Helper close preceded actual driver stop completion")
            }
            driver.onFailure?("owned_shutdown_ordering")
            precondition(session.failure != nil && session.audibleLeases.isEmpty && driver.invalidations > invalidationsBeforeFailure,
                         "Session failure did not synchronously revoke old capture authority")
            if !holdStart { await held.untilEntered() }
            // Let the shutdown task reach its held join/stop before observing.
            for _ in 0..<100 { await Task.yield() }
            precondition(!transport.closed && !transport.commands.contains { $0.action == .close },
                         "Helper terminated before pending capture start/stop retired")
            let replacementID = UUID()
            var replacementFinished = false
            let replacement = Task {
                defer { replacementFinished = true }
                do {
                    try await session.loadForQualification(id: replacementID, generation: UUID(), html: "replacement", options: .init(), callbacks: states.callbacks)
                    preconditionFailure("Cancelled replacement unexpectedly installed")
                } catch is CancellationError {} catch { preconditionFailure("Replacement escaped shutdown barrier: \(error)") }
            }
            for _ in 0..<1000 {
                if session.validationHasPendingLoad(replacementID) { break }
                await Task.yield()
            }
            precondition(session.validationHasPendingLoad(replacementID) && !replacementFinished &&
                         !transport.commands.contains { $0.action == .load && $0.widgetID == replacementID },
                         "New demand bypassed old capture cleanup")
            // Withdraw the queued replacement, so this inert fixture never
            // falls through to a real helper launch after the old owner closes.
            session.release(replacementID)
            held.release()
            await session.waitUntilStopped(); await replacement.value
            precondition(transport.closeCount == 1 && !driver.isCapturing && session.demandCount == 0)
            print("PASS: actual session failure retains old helper through held capture \(holdStart ? "start join" : "stop"), fences replacement demand and closes once after cleanup; inert transport/driver only")
        }
        // Actual session consumption of a current capture-owner proof. A retired
        // demand while capture start is held must never reach helper Resume.
        do {
            let transport = Transport(), driver = Driver(), states = States(), held = HeldStart()
            let session = BrowserWidgetHelperSession(applicationURL: path, mixer: AudioMixEngine(),
                validationAudioDriver: driver, transportForQualification: transport)
            session.prepareMixerForAudio = { .init(isCurrent: { true }) }
            transport.reply = { [weak session] in session?.validationReceive($0) }
            let id = UUID(), generation = UUID(), lease = BrowserWidgetPageLease(widgetID: id, generation: generation)
            try await session.loadForQualification(id: id, generation: generation, html: "owned-proof", options: .init(), callbacks: states.callbacks)
            let owner = BrowserCaptureExclusionOwner(); owner.publish(.installed(42))
            var epoch = UUID(); let first = epoch
            let proof = BrowserCaptureExclusionPermit(id: first, helperPID: 42,
                isCurrent: { epoch == first && owner.accepts(helperPID: 42, demanded: true) })
            driver.beforeStart = { await held.wait() }
            session.setProgramAudioDemand([lease], exclusions: proof)
            await held.untilEntered()
            owner.publish(.pending); epoch = UUID()
            session.setProgramAudioDemand([lease], exclusions: nil)
            held.release(); await session.waitUntilStopped()
            precondition(session.audibleLeases.isEmpty && !driver.isCapturing && !transport.commands.contains { $0.action == .resume },
                         "Retired capture owner resumed helper after held capture start")
            driver.beforeStart = nil
            owner.publish(.installed(42)); let replacement = epoch
            session.setProgramAudioDemand([lease], exclusions: .init(id: replacement, helperPID: 42,
                isCurrent: { epoch == replacement && owner.accepts(helperPID: 42, demanded: true) }))
            await session.waitUntilStopped()
            precondition(session.audibleLeases == [lease], "Valid replacement exclusion generation remained latched unavailable")
            session.setProgramAudioDemand([lease], exclusions: .init(id: UUID(), helperPID: 43, isCurrent: { true }))
            precondition(session.audibleLeases.isEmpty)
            await session.waitUntilStopped()
            precondition(!driver.isCapturing, "Old PID proof authorized a different helper")
            session.release(id); await session.waitUntilStopped()
            print("PASS: actual helper session rejects retired capture/demand proof during held start, accepts fresh proof without latch and rejects other helper PID; inert driver only")
        }
        // A permit can retire during one page's Resume acknowledgment. No
        // sibling page may receive a later Resume from that obsolete proof.
        do {
            let transport = Transport(), driver = Driver(), states = States()
            let session = BrowserWidgetHelperSession(applicationURL: path, mixer: AudioMixEngine(),
                validationAudioDriver: driver, transportForQualification: transport)
            session.prepareMixerForAudio = { .init(isCurrent: { true }) }
            transport.reply = { [weak session] in session?.validationReceive($0) }
            var valid = true
            let first = UUID(), sibling = UUID(), generation = UUID()
            try await session.loadForQualification(id: first, generation: generation, html: "first", options: .init(), callbacks: states.callbacks)
            try await session.loadForQualification(id: sibling, generation: generation, html: "sibling", options: .init(), callbacks: states.callbacks)
            transport.onSend = { if $0.action == .resume { valid = false } }
            session.setProgramAudioDemand([.init(widgetID: first, generation: generation), .init(widgetID: sibling, generation: generation)],
                exclusions: .init(id: UUID(), helperPID: 42, isCurrent: { valid }))
            await session.waitUntilStopped()
            precondition(transport.commands.filter { $0.action == .resume }.count == 1 && session.audibleLeases.isEmpty && !driver.isCapturing,
                         "Retired permit resumed a sibling page after an awaited acknowledgment")
            session.release(first); session.release(sibling); await session.waitUntilStopped()
            print("PASS: actual helper rechecks current owner proof before each page Resume, including retirement during sibling acknowledgment")
        }
        // Registration without a current mixer preparer is a visual-only
        // demand. It must never resume the page/capture at default gain.
        do {
            let transport = Transport(), driver = Driver(), states = States(), mixer = AudioMixEngine()
            let session = BrowserWidgetHelperSession(applicationURL: path, mixer: mixer,
                validationAudioDriver: driver, transportForQualification: transport)
            transport.reply = { [weak session] in session?.validationReceive($0) }
            let id = UUID(), generation = UUID(), lease = BrowserWidgetPageLease(widgetID: id,generation: generation)
            try await session.loadForQualification(id: id,generation: generation,html: "visual-only",options: .init(),callbacks: states.callbacks)
            session.setProgramAudioDemand([lease],applyingExclusions: session.requiredSystemAudioExclusions)
            await session.waitUntilStopped()
            precondition(driver.starts == 0 && session.audibleLeases.isEmpty && session.demandCount == 1,
                         "Missing mixer preparation resumed an unseeded helper route")
            precondition(!transport.commands.contains { $0.action == .resume } && session.audioUnavailableReason?.contains("preparation") == true)
            session.prepareMixerForAudio = { .init(isCurrent: { true }) }
            await session.waitUntilStopped()
            precondition(driver.starts == 1 && session.audibleLeases == [lease], "Late current preparation did not reconcile existing Program intent")
            session.prepareMixerForAudio = nil
            precondition(session.audibleLeases.isEmpty, "Removing mixer ownership did not synchronously revoke helper authority")
            await session.waitUntilStopped()
            precondition(!driver.isCapturing && session.demandCount == 1 && !states.hasFailure && session.failure == nil,
                         "Unregistered helper retained capture or unnecessarily destroyed its visual page")
            session.release(id); await session.waitUntilStopped()
        }
        for rejected in [BrowserWidgetAudioCommand.Action.stop, .suspend, .resume] {
            let transport = Transport(), driver = Driver(), firstStates = States(), siblingStates = States()
            let session = BrowserWidgetHelperSession(applicationURL: path, mixer: AudioMixEngine(),
                validationAudioDriver: driver, transportForQualification: transport)
            session.prepareMixerForAudio = { .init(isCurrent: { true }) }
            transport.reply = { [weak session] in session?.validationReceive($0) }
            let first = UUID(), sibling = UUID(), generation = UUID()
            try await session.loadForQualification(id: first, generation: generation, html: "first", options: .init(), callbacks: firstStates.callbacks)
            try await session.loadForQualification(id: sibling, generation: UUID(), html: "sibling", options: .init(), callbacks: siblingStates.callbacks)
            await session.waitUntilStopped()
            precondition(session.demandCount == 2 && !session.audioIsCapturing)
            transport.rejectedAction = rejected
            if rejected == .stop { session.release(first) }
            else if rejected == .suspend { session.setSuspended(id: first, generation: generation, suspended: true) }
            else {
                session.setProgramAudioDemand([.init(widgetID: first, generation: generation)],
                    applyingExclusions: session.requiredSystemAudioExclusions)
            }
            await session.waitUntilStopped()
            precondition(session.demandCount == 0 && transport.closed && siblingStates.hasFailure,
                         "Rejected current Stop/Suspend/authorized Resume must retire the shared helper")
            precondition(session.failure != nil && !session.audioIsCapturing && session.demandedAudioChannels.isEmpty)
        }
        let transport = Transport(), driver = Driver(), firstStates = States(), siblingStates = States()
        let session = BrowserWidgetHelperSession(applicationURL: path, mixer: AudioMixEngine(),
            validationAudioDriver: driver, transportForQualification: transport)
        session.prepareMixerForAudio = { .init(isCurrent: { true }) }
        transport.reply = { [weak session] in session?.validationReceive($0) }
        let first = UUID(), sibling = UUID(), generation = UUID()
        try await session.loadForQualification(id: first, generation: generation, html: "first", options: .init(), callbacks: firstStates.callbacks)
        try await session.loadForQualification(id: sibling, generation: UUID(), html: "sibling", options: .init(), callbacks: siblingStates.callbacks)
        await session.waitUntilStopped()
        session.setSuspended(id: first, suspended: false)
        await session.waitUntilStopped()
        precondition(!transport.commands.contains { $0.action == .resume }, "Preview-only demand cannot authorize Resume")
        session.setProgramAudioDemand([.init(widgetID: first, generation: generation)], applyingExclusions: session.requiredSystemAudioExclusions)
        await session.waitUntilStopped()
        precondition(session.audibleLeases == [.init(widgetID: first, generation: generation)])
        precondition(transport.commands.filter { $0.action == .resume }.allSatisfy { $0.widgetID == first && $0.generation == generation && $0.requestID != nil })
        let count = transport.commands.count
        session.setSuspended(id: first, generation: UUID(), suspended: true)
        precondition(transport.commands.count == count, "Stale suspension must not touch the current page")
        session.release(first); await session.waitUntilStopped()
        precondition(session.demandCount == 1 && !transport.closed && !siblingStates.hasFailure && session.failure == nil)
        precondition(transport.commands.contains { $0.action == .stop && $0.widgetID == first && $0.generation == generation && $0.requestID != nil })
        session.release(sibling); await session.waitUntilStopped()
        precondition(transport.closed && session.demandCount == 0 && !BrowserWidgetAudioIdentity.productionRouteQualified)
        print("PASS: shipping helper requires current mixer registration, fences withdrawal and current-generation ACK lifecycle; rejects Stop/Suspend/authorized Resume backpressure, forbids Preview-only Resume, preserves sibling demand and refuses stale commands. Inert driver; no helper/SCK/device/PCM qualification.")
    }
}
