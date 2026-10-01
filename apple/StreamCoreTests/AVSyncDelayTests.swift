import Foundation
import Testing
@testable import StreamCore

/// A10 (issue #122): the pure delay math, the duck-envelope state machine,
/// and the persisted settings round-trips behind A/V alignment and ducking.
@Suite("A10 A/V delay math")
struct AVSyncDelayTests {
    @Test("Audio delay converts ms to sample frames at the engine rate")
    func audioFrames() {
        #expect(AVSyncDelay.audioFrames(forMilliseconds: 500, sampleRate: 48_000) == 24_000)
        #expect(AVSyncDelay.audioFrames(forMilliseconds: 100, sampleRate: 48_000) == 4_800)
        #expect(AVSyncDelay.audioFrames(forMilliseconds: 33.3, sampleRate: 48_000) == 1_598)
        #expect(AVSyncDelay.audioFrames(forMilliseconds: 0, sampleRate: 48_000) == 0)
    }

    @Test("Audio delay is bounded and rejects nonsense input")
    func audioFramesClamped() {
        // The documented bound keeps the read window inside the ring's
        // delay headroom (500 ms → 24k frames @48 kHz).
        #expect(AVSyncDelay.audioFrames(forMilliseconds: 10_000, sampleRate: 48_000) == 24_000)
        #expect(AVSyncDelay.audioFrames(forMilliseconds: -50, sampleRate: 48_000) == 0)
        #expect(AVSyncDelay.audioFrames(forMilliseconds: .nan, sampleRate: 48_000) == 0)
        #expect(AVSyncDelay.audioFrames(forMilliseconds: .infinity, sampleRate: 48_000) == 0)
    }

    @Test("Video delay converts ms to output frames at the tick rate")
    func videoFrames() {
        #expect(AVSyncDelay.videoFrames(forMilliseconds: 500, framesPerSecond: 30) == 15)
        #expect(AVSyncDelay.videoFrames(forMilliseconds: 500, framesPerSecond: 60) == 30)
        #expect(AVSyncDelay.videoFrames(forMilliseconds: 100, framesPerSecond: 24) == 2)
        #expect(AVSyncDelay.videoFrames(forMilliseconds: 0, framesPerSecond: 30) == 0)
    }

    @Test("Video delay is bounded and rejects nonsense input")
    func videoFramesClamped() {
        #expect(AVSyncDelay.videoFrames(forMilliseconds: 10_000, framesPerSecond: 60) == 30)
        #expect(AVSyncDelay.videoFrames(forMilliseconds: -50, framesPerSecond: 30) == 0)
        #expect(AVSyncDelay.videoFrames(forMilliseconds: .nan, framesPerSecond: 30) == 0)
    }

    @Test("Envelope times convert to whole chunks, never zero")
    func chunkCount() {
        let chunkSeconds = 512.0 / 48_000.0   // the engine's ~10.7 ms chunk
        #expect(AVSyncDelay.chunkCount(forMilliseconds: 30, chunkDurationSeconds: chunkSeconds) == 3)
        #expect(AVSyncDelay.chunkCount(forMilliseconds: 1, chunkDurationSeconds: chunkSeconds) == 1)
        #expect(AVSyncDelay.chunkCount(forMilliseconds: 0, chunkDurationSeconds: chunkSeconds) == 1)
        #expect(AVSyncDelay.chunkCount(forMilliseconds: 400, chunkDurationSeconds: chunkSeconds) == 38)
    }
}

@Suite("A10 duck envelope")
struct DuckEnvelopeTests {
    private let parameters = DuckEnvelope.Parameters(attackChunks: 3, holdChunks: 4, releaseChunks: 6)

    @Test("Speech engages the duck with the attack ramp exactly once")
    func attackEngagesOnce() {
        var envelope = DuckEnvelope()
        let first = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        #expect(first.changed)
        #expect(first.targetGain == 0.25)
        #expect(first.rampChunks == 3)
        #expect(envelope.phase == .ducking)
        // Steady speech: no further ramp pushes (the engine never re-triggers).
        let steady = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        #expect(!steady.changed)
        #expect(steady.targetGain == 0.25)
    }

    @Test("Silence shorter than the hold keeps the duck engaged")
    func holdKeepsDuck() {
        var envelope = DuckEnvelope()
        _ = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        for _ in 0..<4 {
            let decision = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
            #expect(!decision.changed)
            #expect(decision.targetGain == 0.25)
            #expect(envelope.phase == .ducking)
        }
    }

    @Test("Silence past the hold releases toward unity with the release ramp")
    func releaseAfterHold() {
        var envelope = DuckEnvelope()
        _ = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        for _ in 0..<4 {
            _ = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        }
        let released = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        #expect(released.changed)
        #expect(released.targetGain == 1)
        #expect(released.rampChunks == 6)
        #expect(envelope.phase == .releasing)
        // Continued silence: steady, no re-trigger.
        let steady = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        #expect(!steady.changed)
        #expect(steady.targetGain == 1)
    }

    @Test("Speech during the hold re-arms it without any gain push")
    func speechDuringHold() {
        var envelope = DuckEnvelope()
        _ = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        for _ in 0..<3 {
            _ = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        }
        let resumed = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        #expect(!resumed.changed)   // already ducking — hold simply re-arms
        #expect(envelope.phase == .ducking)
        // ...and the full hold is available again.
        for _ in 0..<4 {
            _ = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        }
        let released = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        #expect(released.changed)
        #expect(released.targetGain == 1)
    }

    @Test("Speech during the release re-engages the attack from the current gain")
    func speechDuringRelease() {
        var envelope = DuckEnvelope()
        _ = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        for _ in 0...4 {
            _ = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        }
        #expect(envelope.phase == .releasing)
        let reengaged = envelope.advance(speechActive: true, duckGain: 0.25, parameters: parameters)
        #expect(reengaged.changed)
        #expect(reengaged.targetGain == 0.25)
        #expect(reengaged.rampChunks == 3)
        #expect(envelope.phase == .ducking)
    }

    @Test("An idle envelope is a silent no-op")
    func idle() {
        var envelope = DuckEnvelope()
        let decision = envelope.advance(speechActive: false, duckGain: 0.25, parameters: parameters)
        #expect(!decision.changed)
        #expect(decision.targetGain == 1)
        #expect(envelope.phase == .open)
    }

    @Test("A zero-chunk hold releases on the first silent chunk")
    func zeroHold() {
        var envelope = DuckEnvelope()
        let noHold = DuckEnvelope.Parameters(attackChunks: 3, holdChunks: 0, releaseChunks: 6)
        _ = envelope.advance(speechActive: true, duckGain: 0.25, parameters: noHold)
        let released = envelope.advance(speechActive: false, duckGain: 0.25, parameters: noHold)
        #expect(released.changed)
        #expect(released.targetGain == 1)
    }
}

@Suite("A10 ducking settings")
struct DuckingSettingsTests {
    @Test("Threshold and reduction convert to linear gains")
    func linearConversions() {
        var settings = DuckingSettings()
        settings.thresholdDb = -40
        #expect(abs(settings.thresholdLinear - 0.01) < 0.000_1)
        settings.reductionDb = 12
        #expect(abs(settings.duckGain - 0.251_19) < 0.001)
        settings.reductionDb = 0
        #expect(settings.duckGain == 1)
    }

    @Test("Defaults are valid; out-of-range values report errors")
    func validation() {
        #expect(DuckingSettings().validationError == nil)
        var settings = DuckingSettings()
        settings.thresholdDb = 5
        #expect(settings.validationError != nil)
        settings = DuckingSettings()
        settings.reductionDb = 100
        #expect(settings.validationError != nil)
        settings = DuckingSettings()
        settings.attackMs = 0
        #expect(settings.validationError != nil)
    }

    @Test("Ducking settings round-trip through encode/decode")
    func roundTrip() throws {
        var settings = DuckingSettings()
        settings.isEnabled = true
        settings.sidechainLabels = ["mic.default"]
        settings.targetLabels = ["media.playlist-1", "app.com.spotify.client"]
        settings.thresholdDb = -35
        settings.reductionDb = 18
        settings.attackMs = 20
        settings.holdMs = 250
        settings.releaseMs = 900
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(DuckingSettings.self, from: data)
        #expect(restored == settings)
    }

    @Test("A partial ducking blob decodes missing keys to defaults")
    func partialBlobDefaults() throws {
        let json = #"{"isEnabled": true, "reductionDb": 20}"#.data(using: .utf8)!
        let restored = try JSONDecoder().decode(DuckingSettings.self, from: json)
        #expect(restored.isEnabled)
        #expect(restored.reductionDb == 20)
        #expect(restored.thresholdDb == -40)
        #expect(restored.sidechainLabels.isEmpty)
        #expect(restored.targetLabels.isEmpty)
    }
}

@Suite("A10 settings persistence")
struct AVSyncSettingsCodableTests {
    private func decode(_ json: String) throws -> StreamSettings {
        try JSONDecoder().decode(StreamSettings.self, from: json.data(using: .utf8)!)
    }

    @Test("A blob written before A10 existed decodes to no delays and ducking off")
    func missingKeysDefault() throws {
        let s = try decode(#"{"micVolume": 1.1}"#)
        #expect(s.audioDelaysMs.isEmpty)
        #expect(s.videoDelaysMs.isEmpty)
        #expect(s.ducking == DuckingSettings())
        #expect(s.ducking.isEnabled == false)
    }

    @Test("Delays and ducking round-trip through the settings blob")
    func roundTrip() throws {
        var ducking = DuckingSettings()
        ducking.isEnabled = true
        ducking.sidechainLabels = ["mic.default"]
        ducking.targetLabels = ["media.playlist-9"]
        let original = StreamSettings(
            audioDelaysMs: ["mic.default": 120],
            videoDelaysMs: ["source.B8D2C4A0-1234-4A7B-9C0D-1A2B3C4D5E6F": 66],
            ducking: ducking)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored == original)
        #expect(restored.audioDelaysMs["mic.default"] == 120)
        #expect(restored.videoDelaysMs.count == 1)
        #expect(restored.ducking.isEnabled)
        #expect(restored.ducking.targetLabels == ["media.playlist-9"])
    }
}
