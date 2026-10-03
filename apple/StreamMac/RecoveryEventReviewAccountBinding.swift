import Combine
import StreamCore

private struct RecoveryAccountAuthority: Equatable {
    let clientID: String
    let hasCredential: Bool
    let scopes: [String]
}

@MainActor extension RecoveryEventReviewCoordinator {
    /// One runtime binding hook; this does not request provider data. The
    /// existing recovery view alone offers explicit Verify actions.
    func bindAccounts(_ accounts: ProviderAccountSession) {
        bind(authorization: { [weak accounts] provider in await accounts?.recoveryAuthorizationGeneration(provider) },
             verify: { [weak accounts] identity in
                guard let accounts else { throw ProviderFailure(.unavailable) }
                return try await accounts.verifyRecoveryEvent(identity)
             })
        // Forget/authorize publishes at the intent boundary before asynchronous
        // vault work finishes. Retire all displayed receipts immediately.
        let authority = accounts.$accounts.map { snapshots in
            let value = snapshots[.youtube] ?? .init()
            return RecoveryAccountAuthority(clientID: value.clientID, hasCredential: value.hasCredential, scopes: value.scopes.sorted())
        }.removeDuplicates().dropFirst().map { _ in () }
        let intent = accounts.$managedReadRevision.dropFirst().map { _ in () }
        observeAuthorizationChanges(Publishers.Merge(authority, intent).eraseToAnyPublisher())
    }
}
