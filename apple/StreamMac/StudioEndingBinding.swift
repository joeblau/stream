import Combine
import Foundation
import StreamCore

@MainActor private final class EndingProgramObservation {
    var revision = UUID()
    var observation: AnyCancellable?
    init(_ program: PreviewProgramModel) {
        observation = program.$programScene.sink { [weak self] _ in self?.revision = UUID() }
    }
}

extension StreamController {
    /// Root calls once per retained runtime after accounts/dispatcher creation.
    /// All outro publication uses the existing shared command/Take path.
    @MainActor func bindEnding(accounts: ProviderAccountSession, dispatcher: StudioCommandDispatcher, previewProgram: PreviewProgramModel) {
        let observation = EndingProgramObservation(previewProgram)
        ending.bind(.init(targets: { [weak self] in
            guard let self else { return [] }
            let sessions = self.destinationOutputs.endingSessions
            let active = sessions.map { StudioEndingTarget(id: $0.destination.id, name: $0.destination.name, session: $0.token, binding: $0.destination.providerBinding) }
            let ids = Set(active.map(\.id))
            return active + self.destinations.saved.filter { !ids.contains($0.id) }.map {
                StudioEndingTarget(id: $0.id, name: $0.name, session: nil, binding: $0.providerBinding)
            }
        }, stopLocal: { [weak self, weak dispatcher] target in
            guard let self, let token = target.session else { return .superseded }
            // An existing macro cannot restart an output after this deliberate
            // stop. Cancelling does not stop the independent recorder.
            dispatcher?.macros.cancel()
            let result = await self.destinationOutputs.stopIfCurrent(target.id, token: token)
            switch result { case .stopped: return .stopped; case .superseded: return .superseded; case .unconfirmed: return .unconfirmed }
        }, localReceipt: { [weak self] target in
            guard let self, let token = target.session else { return .superseded }
            switch self.destinationOutputs.stopReceipt(target.id, token: token) {
            case .stopped: return .stopped; case .superseded: return .superseded; case .unconfirmed: return .unconfirmed
            }
        }, remote: { [weak accounts] binding, review in
            guard let accounts else { return .init(.unconfirmed) }; return await accounts.endRemote(binding, reviewOnly: review)
        }, canEndRemote: { [weak accounts] binding in
            guard let accounts, binding.provider == .youtube, binding.eventID != nil else { return false }
            let snapshot = accounts.snapshot(.youtube)
            return snapshot.hasCredential && accounts.canRequest(.youtube) &&
                (snapshot.scopes.contains("https://www.googleapis.com/auth/youtube") || snapshot.scopes.contains("https://www.googleapis.com/auth/youtube.force-ssl"))
        }), sceneHooks: .init(choices: { [weak dispatcher] in
            dispatcher?.state.scenes.map { .init(id: $0.id.rawValue, name: $0.name) } ?? []
        }, take: { [weak dispatcher, weak previewProgram] id in
            guard let dispatcher, let previewProgram, !dispatcher.state.hasPendingStagedEdits,
                  let scene = dispatcher.state.scenes.first(where: { $0.id.rawValue == id }) else { throw ProviderFailure(.invalidRequest) }
            guard dispatcher.execute(.selectScene(scene.id)).error == nil,
                  dispatcher.execute(.take).error == nil,
                  previewProgram.programScene?.id == scene.id else { throw ProviderFailure(.unavailable) }
            return .init(sceneID: id, revision: observation.revision)
        }, matches: { [weak previewProgram] receipt in
            previewProgram?.programScene?.id.rawValue == receipt.sceneID && observation.revision == receipt.revision
        }, transitionComplete: { [weak dispatcher] in dispatcher?.transitions.hasActiveTransition == false }))
        ending.retainBindings([
            destinationOutputs.$states.sink { [weak ending] _ in Task { @MainActor in ending?.refreshAvailability() } },
            destinations.$saved.sink { [weak ending] _ in Task { @MainActor in ending?.refreshAvailability() } },
            accounts.$accounts.sink { [weak ending] _ in Task { @MainActor in ending?.refreshAvailability() } },
            dispatcher.$state.sink { [weak ending] _ in Task { @MainActor in ending?.refreshAvailability() } }
        ])
    }
}
