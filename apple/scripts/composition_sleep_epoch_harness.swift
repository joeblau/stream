import Foundation

@main enum CompositionSleepEpochHarness {
    static func record(_ epoch: UUID, sequence: Int64, completed: Bool) -> Bool {
        CompositionHotPathProfile.shared.recordClockSleep(epoch: epoch, sequence: sequence,
            requestedAt: 10, returnedAt: 10.04, requestedMS: 30, returnedMS: 10,
            tolerance: "zero", completed: completed)
    }
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = CompositionHotPathProfile.shared
        profile.reset()
        let retired = profile.captureEpoch()
        profile.reset()
        let current = profile.captureEpoch()
        precondition(retired != current)
        // Resume both an old canceled sleep and an old successful sleep after
        // the new case reset. Neither its event nor any scalar may be recorded.
        precondition(!record(retired, sequence: 1, completed: false))
        precondition(!record(retired, sequence: 2, completed: true))
        precondition(record(current, sequence: 3, completed: false))
        precondition(record(current, sequence: 4, completed: true))
        let reportURL = directory.appendingPathComponent("epoch-case.json")
        try profile.write(reportURL, caseIndex: 0)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
        let spans = report["spans"] as! [String: [String: Any]]
        for name in ["clockSleepRequestedDelay", "clockSleepWall", "clockSleepReturnLateness"] {
            precondition(spans[name]?["count"] as? Int == 1, "Canceled/stale sleep polluted successful aggregates")
        }
        let traceURL = directory.appendingPathComponent(report["eventFile"] as! String)
        let trace = try JSONSerialization.jsonObject(with: Data(contentsOf: traceURL)) as! [String: Any]
        let boundaries = (trace["events"] as! [[String: Any]]).filter { $0["phase"] as? String == "clockSleepBoundary" }
        precondition(boundaries.count == 2)
        precondition(boundaries.map { $0["sequence"] as! Int } == [3, 4])
        precondition(boundaries.allSatisfy { $0["profileEpoch"] as? String == current.uuidString })
        precondition(boundaries[0]["completed"] as? Bool == false && boundaries[1]["completed"] as? Bool == true)
        profile.reset()
        precondition(!record(current, sequence: 5, completed: true), "A second reset must retire the prior clock epoch")
        try profile.write(directory.appendingPathComponent("next-case.json"), caseIndex: 1)
        let next = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("next-case.json"))) as! [String: Any]
        precondition((next["spans"] as! [String: Any])["clockSleepWall"] == nil)
        print("PASS actual helper: stale canceled/successful returns rejected after reset; current canceled event excluded from successful aggregates; second reset retains no sleep data. No clocks, rendering or media started.")
    }
}
