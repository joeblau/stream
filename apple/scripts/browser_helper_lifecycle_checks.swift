import CoreMedia
import Foundation

/// Exercises the shipping session against command backpressure only. No helper,
/// ScreenCaptureKit session, audio device or mixer is started by these checks.
@MainActor enum BrowserHelperLifecycleChecks {
    @MainActor private final class Transport: BrowserWidgetHelperTransport {
        let pid: Int32 = 42
        var rejectedAction: BrowserWidgetAudioCommand.Action?
        var commands: [BrowserWidgetAudioCommand] = []
        var closed = false
        func send(_ value: BrowserWidgetAudioCommand) throws {
            if value.action == rejectedAction { throw BrowserWidgetHelperSession.SessionError.unavailable }
            commands.append(value)
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
        for rejected in [BrowserWidgetAudioCommand.Action.stop, .suspend, .resume] {
            let transport = Transport(), firstStates = States(), siblingStates = States()
            let session = BrowserWidgetHelperSession(applicationURL: path, transportForQualification: transport) { _ in
                preconditionFailure("A command-only fixture must never deliver audio")
            }
            let first = UUID(), sibling = UUID(), generation = UUID()
            try await session.loadForQualification(id: first, generation: generation, html: "first", options: .init(), callbacks: firstStates.callbacks)
            try await session.loadForQualification(id: sibling, generation: UUID(), html: "sibling", options: .init(), callbacks: siblingStates.callbacks)
            precondition(session.demandCount == 2 && !session.audioIsCapturing)
            transport.rejectedAction = rejected
            if rejected == .stop { session.release(first) }
            else { session.setSuspended(id: first, suspended: rejected == .suspend) }
            await session.waitUntilStopped()
            precondition(session.demandCount == 0 && transport.closed && siblingStates.hasFailure,
                         "An unconfirmed lifecycle command must retire the shared helper and report sibling failure")
            precondition(session.failure == (rejected == .stop ? "helper_stop_unconfirmed" : "helper_suspension_unconfirmed"))
            precondition(!session.audioIsCapturing && session.demandedAudioChannels.isEmpty)
        }
        let transport = Transport(), firstStates = States(), siblingStates = States()
        let session = BrowserWidgetHelperSession(applicationURL: path, transportForQualification: transport) { _ in
            preconditionFailure("A command-only fixture must never deliver audio")
        }
        let first = UUID(), sibling = UUID(), generation = UUID()
        try await session.loadForQualification(id: first, generation: generation, html: "first", options: .init(), callbacks: firstStates.callbacks)
        try await session.loadForQualification(id: sibling, generation: UUID(), html: "sibling", options: .init(), callbacks: siblingStates.callbacks)
        session.setSuspended(id: first, suspended: true)
        session.setSuspended(id: first, suspended: false)
        session.release(first)
        precondition(session.demandCount == 1 && !transport.closed && !siblingStates.hasFailure && session.failure == nil)
        let lifecycle = transport.commands.filter { [.suspend, .resume, .stop].contains($0.action) }
        precondition(lifecycle.map(\.action) == [.suspend, .resume, .stop] && lifecycle.allSatisfy { $0.widgetID == first })
        precondition(lifecycle.prefix(2).allSatisfy { $0.generation == generation })
        session.release(sibling); await session.waitUntilStopped()
        precondition(transport.closed && session.demandCount == 0 && !BrowserWidgetAudioIdentity.productionRouteQualified)
        print("PASS: shipping helper session command rejection retires shared helper on unconfirmed Stop/Suspend/Resume; successful commands retain exact widget/generation and sibling demand. No helper launch, capture or PCM routing qualification.")
    }
}
