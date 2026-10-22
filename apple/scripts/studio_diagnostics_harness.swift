import Foundation

@main struct StudioDiagnosticsHarness {
    static func main() throws {
        let secret = "private-token-DO-NOT-EXPORT"
        let id = UUID().uuidString
        var snapshot = StudioDiagnosticSnapshot()
        snapshot.streamState = secret
        snapshot.recordingState = "recording"
        snapshot.program.totalRenderMilliseconds = .nan
        snapshot.resourcePreviewLevel = secret
        snapshot.programKernel.backend = secret
        snapshot.programKernel.unavailableReason = secret
        snapshot.sources = (0..<300).map { (index: Int) in
            SourceDiagnosticSnapshot(id: "\(secret)-\(index)", kind: secret, state: secret, deliveredFrames: index)
        }
        snapshot.outputs = (0..<80).map { _ in
            DestinationDiagnosticSnapshot(id: id, state: "live", startedAt: nil, targetFPS: 30,
                achievedFPS: 29, bitrate: 4_000_000, socketQueueBytes: nil, stalledSeconds: nil,
                encoderCongestionDrops: nil, videoQueueDepth: 1, videoMailboxDrops: 3)
        }
        snapshot.audioUnderruns = Dictionary(uniqueKeysWithValues: (0..<300).map { ("\(secret)-\($0)", Int64($0)) })
        snapshot.audioTapDrops = snapshot.audioUnderruns
        snapshot.sourceAudioClocks = snapshot.audioUnderruns.mapValues { _ in .unsupported }
        snapshot.events = (0..<300).map { _ in .init(time: Date(), state: "output.\(id).live") }
        snapshot.events.append(.init(time: Date(), state: secret))
        let data = try snapshot.redactedExportData()
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains(secret) && !text.contains(id), "Raw resource IDs and unrecognized strings must not escape")
        precondition(data.count <= StudioDiagnosticSnapshot.maximumExportBytes)
        let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sources = document["sources"] as! [[String: Any]]
        let outputs = document["outputs"] as! [[String: Any]]
        let events = document["events"] as! [[String: Any]]
        precondition(sources.count == 256 && outputs.count == 64 && events.count == 256)
        precondition((document["audioUnderruns"] as! [String: Any]).count == 256)
        precondition(document["streamState"] as! String == "unknown")
        precondition(document["recordingState"] as! String == "recording")
        precondition(sources.allSatisfy { $0["kind"] as! String == "other" && $0["state"] as! String == "unknown" })
        let outputID = outputs[0]["id"] as! String
        precondition(events.dropLast().allSatisfy { $0["state"] as! String == "output.\(outputID).live" })
        precondition(events.last!["state"] as! String == "unknown")
        precondition((document["program"] as! [String: Any])["totalRenderMilliseconds"] as! String == "unavailable")
        // Matching channels remain correlatable within one bundle; bundles do
        // not expose an enduring machine/channel fingerprint.
        precondition(Set((document["audioUnderruns"] as! [String: Any]).keys) == Set((document["audioTapDrops"] as! [String: Any]).keys))
        precondition(Set((document["sourceAudioClocks"] as! [String: Any]).keys) == Set((document["audioUnderruns"] as! [String: Any]).keys))
        var timers = snapshot
        timers.outputs = Array(snapshot.outputs.prefix(2))
        let oldStart = Date(timeIntervalSince1970: 100), liveStart = Date(timeIntervalSince1970: 200)
        timers.outputs[0].state = "failed"; timers.outputs[0].startedAt = oldStart
        timers.outputs[1].state = "live"; timers.outputs[1].startedAt = liveStart
        precondition(timers.liveSessionStartedAt == liveStart, "Historical failure cannot drive the live timer")
        timers.outputs[1].state = "reconnecting"
        precondition(timers.liveSessionStartedAt == liveStart, "Reconnect must preserve the acknowledged timer")
        timers.outputs[1].state = "failed"
        precondition(timers.liveSessionStartedAt == nil, "No active output means no live timer")
        let second = try JSONSerialization.jsonObject(with: snapshot.redactedExportData()) as! [String: Any]
        precondition((second["outputs"] as! [[String: Any]])[0]["id"] as! String != outputID)
        precondition(snapshot.outputs[0].id == id && snapshot.sources.count == 300, "Export cannot mutate the live inspector snapshot")
        print("PASS: bounded diagnostic collections, state allowlists, fresh correlated pseudonyms, unavailable numeric probes and immutable runtime snapshot (\(data.count) bytes)")
    }
}
