import CoreMedia
import Foundation

/// Command-only qualification of the shipping ACK/revision state machine.
/// The inert driver never launches SCK, renders PCM or opens an audio device.
@MainActor enum BrowserHelperLifecycleChecks {
    @MainActor private final class Driver: BrowserWidgetAudioDriver {
        var isCapturing = false
        var starts = 0
        let requiresScreenCaptureAccess = false
        var onFailure: (@MainActor (String) -> Void)?
        func start(helperPID: Int32) async throws { precondition(helperPID == 42); starts += 1; isCapturing = true }
        func invalidateInput() {}
        func stop() async { isCapturing = false }
    }
    @MainActor private final class Transport: BrowserWidgetHelperTransport {
        let pid: Int32 = 42
        var rejectedAction: BrowserWidgetAudioCommand.Action?
        var commands: [BrowserWidgetAudioCommand] = []
        var closed = false
        var reply: ((BrowserWidgetAudioReply) -> Void)?
        func send(_ value: BrowserWidgetAudioCommand) throws {
            if value.action == rejectedAction { throw BrowserWidgetHelperSession.SessionError.unavailable }
            commands.append(value)
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
        func close() { closed = true }
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
    static func run() async throws {
        let path = URL(fileURLWithPath: "/unavailable-owned-browser-fixture.app")
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
