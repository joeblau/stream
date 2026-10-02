import Testing
@testable import StreamCore

/// The Keychain ACCOUNT strings are a cross-process contract: the app writes a
/// secret under an account name and the broadcast extension reads it back under
/// the SAME name. A silent rename on either side breaks the handshake with no
/// compile error, so the account derivation is pinned here. This needs no live
/// Keychain access, so it runs deterministically in the host-less test bundle.
@Suite struct KeychainAccountKeyTests {

    @Test("Per-protocol URL/key accounts follow the shared naming scheme")
    func perProtocolAccounts() {
        #expect(KeychainStore.Item.url(.rtmp).account  == "stream.connection.rtmp.url")
        #expect(KeychainStore.Item.url(.rtmps).account == "stream.connection.rtmps.url")
        #expect(KeychainStore.Item.url(.srt).account   == "stream.connection.srt.url")
        #expect(KeychainStore.Item.url(.whip).account  == "stream.connection.whip.url")

        #expect(KeychainStore.Item.key(.rtmp).account  == "stream.connection.rtmp.key")
        #expect(KeychainStore.Item.key(.rtmps).account == "stream.connection.rtmps.key")
        #expect(KeychainStore.Item.key(.srt).account   == "stream.connection.srt.key")
        #expect(KeychainStore.Item.key(.whip).account  == "stream.connection.whip.key")
    }

    @Test("Legacy single-slot accounts keep their pre-multiprotocol names for migration")
    func legacyAccounts() {
        #expect(KeychainStore.Item.legacyURL.account == "stream.connection.url")
        #expect(KeychainStore.Item.legacyKey.account == "stream.connection.key")
    }

    @Test("Every protocol's URL and key accounts are distinct")
    func accountsAreUnique() {
        var accounts = Set<String>()
        for proto in StreamProtocol.allCases {
            accounts.insert(KeychainStore.Item.url(proto).account)
            accounts.insert(KeychainStore.Item.key(proto).account)
        }
        // 4 protocols × (url + key) = 8 unique account names.
        #expect(accounts.count == 8)
    }
}

/// Probes once whether the live Keychain can actually be written in the current
/// environment. A host-less logic-test bundle has no keychain-access-group
/// entitlement, so `SecItemAdd` returns errSecMissingEntitlement and writes fail;
/// there the round-trip suite below is skipped rather than reported red. On a
/// device / host-app configuration the probe succeeds and the tests run for real.
enum KeychainAvailability {
    static let isWritable: Bool = {
        let probe = KeychainStore(service: "com.joeblau.Stream.tests.probe")
        _ = probe.set("probe", for: .url(.rtmp))
        let ok = probe.string(for: .url(.rtmp)) == "probe"
        probe.remove(.url(.rtmp))
        return ok
    }()
}

/// Live Keychain round-trip behavior, exercised only where the Keychain is
/// writable (see `KeychainAvailability`). A dedicated service name isolates these
/// from any real app credentials on the device/simulator.
@Suite struct KeychainStoreRoundTripTests {

    private let store = KeychainStore(service: "com.joeblau.Stream.tests.keychain")

    /// Deletes every account this suite might touch, so runs are independent.
    private func cleanup() {
        for proto in StreamProtocol.allCases {
            store.remove(.url(proto))
            store.remove(.key(proto))
        }
    }

    @Test("A saved secret reads back verbatim", .enabled(if: KeychainAvailability.isWritable))
    func setThenGet() {
        cleanup(); defer { cleanup() }
        #expect(store.set("s3cr3t", for: .key(.rtmps)))
        #expect(store.string(for: .key(.rtmps)) == "s3cr3t")
    }

    @Test("Saving an empty value clears the secret", .enabled(if: KeychainAvailability.isWritable))
    func emptyClears() {
        cleanup(); defer { cleanup() }
        store.set("temp", for: .url(.rtmp))
        #expect(store.set("", for: .url(.rtmp)))
        #expect(store.string(for: .url(.rtmp)) == nil)
    }

    @Test("Whitespace is trimmed before storage", .enabled(if: KeychainAvailability.isWritable))
    func trimsWhitespace() {
        cleanup(); defer { cleanup() }
        store.set("  rtmps://host/live \n", for: .url(.rtmps))
        #expect(store.string(for: .url(.rtmps)) == "rtmps://host/live")
    }

    @Test("Each protocol keeps its own isolated URL and key slots", .enabled(if: KeychainAvailability.isWritable))
    func perProtocolIsolation() {
        cleanup(); defer { cleanup() }
        store.set("rtmp-url", for: .url(.rtmp))
        store.set("srt-url", for: .url(.srt))
        store.set("rtmp-key", for: .key(.rtmp))
        #expect(store.string(for: .url(.rtmp)) == "rtmp-url")
        #expect(store.string(for: .url(.srt)) == "srt-url")
        #expect(store.string(for: .key(.rtmp)) == "rtmp-key")
        // A slot that was never written stays empty.
        #expect(store.string(for: .key(.srt)) == nil)
    }

    @Test("Removing a secret makes it unreadable", .enabled(if: KeychainAvailability.isWritable))
    func removeDeletes() {
        cleanup(); defer { cleanup() }
        store.set("gone-soon", for: .url(.whip))
        store.remove(.url(.whip))
        #expect(store.string(for: .url(.whip)) == nil)
    }
}

@Suite struct KeychainReplacementTests {
    @Test("Replacing an existing credential updates its value in place", .enabled(if: KeychainAvailability.isWritable))
    func replacement() {
        let store = KeychainStore(service: "com.joeblau.Stream.tests.replacement")
        let item = KeychainStore.Item.key(.rtmps)
        defer { store.remove(item) }
        #expect(store.set("old", for: item))
        #expect(store.set("replacement", for: item))
        #expect(store.string(for: item) == "replacement")
        #expect(store.set("", for: item))
        #expect(store.string(for: item) == nil)
    }
}
