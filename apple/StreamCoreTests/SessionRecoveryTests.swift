import Foundation
import Testing
@testable import StreamCore

@Suite struct SessionRecoveryTests {
    @Test("Prior interruption, pending edits and partial recording each warrant explicit review")
    func reviewPolicy() {
        var value = SessionRecoverySnapshot(projectID: UUID(), profileID: UUID())
        #expect(value.needsReview)
        value.cleanExit = true; #expect(!value.needsReview)
        value.hasStagedEdits = true; #expect(value.needsReview)
        value.hasStagedEdits = false
        value.recordings = [.init(sessionID: UUID(), index: 1, file: "Program.mp4", status: .partial, duration: 4)]
        #expect(value.needsReview)
        value.reviewDismissed = true; #expect(!value.needsReview)
    }
    @Test("Metadata roundtrip drops unrecognized credential and raw scene fields")
    func redaction() throws {
        let value = SessionRecoverySnapshot(projectID: UUID(), profileID: UUID())
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object["streamKey"] = "secret-key-sentinel"
        object["endpoint"] = "rtmps://private.example/live?token=secret-token-sentinel"
        object["rawScene"] = ["url": "https://private.example?bearer=secret-bearer-sentinel"]
        let decoded = try JSONDecoder().decode(SessionRecoverySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let output = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!output.contains("sentinel") && !output.contains("private.example") && !output.contains("rawScene"))
    }
    @Test("Local basenames, finite timing, bounded inventories and allowlisted geometry are required")
    func bounds() {
        var value = SessionRecoverySnapshot(projectID: UUID(), profileID: UUID())
        value.recordings = [.init(sessionID: UUID(), index: 1, file: "../escape.mp4", status: .partial, duration: 1)]
        #expect(value.validationError != nil)
        value.recordings = []; value.activeOutputIDs = (0..<11).map { _ in UUID() }
        #expect(value.validationError != nil)
        let duplicate = UUID(); value.activeOutputIDs = [duplicate, duplicate]
        #expect(value.validationError != nil)
        value.activeOutputIDs = []; value.media = [.init(sourceID: UUID(), seconds: .nan)]
        #expect(value.validationError != nil)
        value.media = []; value.stagedLayers = [.init(id: UUID(), sourceID: nil, x: 0, y: 0, width: 1, height: 1, rotation: 0, anchor: "secret URL", isVisible: true)]
        #expect(value.validationError != nil)
    }
    @Test("A delayed media load cannot replay autoplay after paused recovery")
    func pausedMedia() {
        var recovery = PausedMediaRecovery()
        recovery.restore(seconds: 12)
        #expect(recovery.isHeld && !recovery.shouldPlay(autoplay: true, requested: true))
        #expect(recovery.consumePosition() == 12)
        #expect(recovery.consumePosition() == nil && recovery.isHeld)
        recovery.playIntent()
        #expect(recovery.shouldPlay(autoplay: true, requested: false))
        recovery.restore(seconds: 20); recovery.playIntent()
        #expect(recovery.consumePosition() == 20 && recovery.shouldPlay(autoplay: false, requested: true))
        recovery.restore(seconds: 30); recovery.restartIntent()
        #expect(recovery.consumePosition() == nil && !recovery.isHeld)
    }
    @Test("Unknown remote event state stays distinct from verified ended or reconnectable events")
    func remoteState() {
        var value = SessionRecoverySnapshot(projectID: UUID(), profileID: UUID())
        let id = UUID()
        value.remoteEvents = [.init(outputID: id)]
        #expect(value.remoteEvents[0].state == .unknown && value.validationError == nil)
        value.remoteEvents = [.init(outputID: id, state: .ended)]
        #expect(value.validationError != nil)
        value.remoteEvents = [.init(outputID: id, eventID: "event_123", state: .ended)]
        #expect(value.validationError == nil)
        value.remoteEvents = [.init(outputID: id, eventID: "https://provider/event?token=secret", state: .reconnectable)]
        #expect(value.validationError != nil)
    }
}
