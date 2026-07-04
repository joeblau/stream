import Testing
import Foundation
import StreamCore

/// Stable storage and notification identifiers are pinned here because changing
/// them silently disconnects existing settings and live-meter state.
@Suite struct CrossProcessIdentifierTests {

    @Test("App Group and storage keys are the exact shared literals")
    func appGroupConstants() {
        #expect(AppGroup.identifier == "group.com.joeblau.Stream")
        #expect(AppGroup.settingsKey == "stream.settings.v1")
        #expect(AppGroup.keychainService == "com.joeblau.Stream.connection")
    }

    @Test("Darwin notification signal names are the exact shared literals")
    func broadcastSignalNames() {
        #expect(BroadcastControl.stateSignal == "com.joeblau.Stream.broadcast.state")
        #expect(BroadcastControl.micVolumeSignal == "com.joeblau.Stream.broadcast.micVolume")
        #expect(BroadcastControl.micLevelState == "com.joeblau.Stream.broadcast.micLevel")
    }
}

/// `BroadcastState` is the persisted liveness snapshot, so its Codable
/// representation must round-trip losslessly.
@Suite struct BroadcastStateCodableTests {

    @Test("BroadcastState round-trips through JSON")
    func roundTrip() throws {
        let original = BroadcastState(isBroadcasting: true, heartbeat: 1_700_000_000.5)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(BroadcastState.self, from: data)
        #expect(restored.isBroadcasting == original.isBroadcasting)
        #expect(restored.heartbeat == original.heartbeat)
    }

    @Test("BroadcastState decodes from the on-disk JSON shape")
    func decodesFromLiteral() throws {
        let json = #"{"isBroadcasting": false, "heartbeat": 42.25}"#
        let state = try JSONDecoder().decode(BroadcastState.self, from: Data(json.utf8))
        #expect(!state.isBroadcasting)
        #expect(state.heartbeat == 42.25)
    }
}

// NOTE: RecordingStore / BroadcastStateStore / SettingsStore are deliberately NOT
// unit-tested here. They hardcode the shared App Group container, which is real
// and populated on any machine where the app has run (this simulator included),
// so their reads are non-deterministic and their writes would mutate the real
// app's shared state. Exercising them needs an injectable container base URL (a
// small source refactor) or a host-app UI test target — out of scope for this
// pure-logic bundle. The pure pieces they rely on (BroadcastState Codable, the
// AppGroup / BroadcastControl / Keychain-account contracts) ARE covered above.
