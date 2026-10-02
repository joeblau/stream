import Foundation
import Testing
@testable import StreamCore

@Suite struct StreamPreflightTests {
    @Test("Every readiness category appears, and unknown measurements never pass")
    func unknowns() {
        let facts = StreamPreflightFacts()
        #expect(Set(facts.checks.map(\.id)) == ["permissions", "sources", "audio", "credentials", "profile", "storage", "encoders", "uplink"])
        #expect(facts.checks.first { $0.id == "audio" }?.status == .unverified)
        #expect(facts.checks.first { $0.id == "encoders" }?.status == .unverified)
        #expect(facts.checks.first { $0.id == "uplink" }?.status == .unverified)
        #expect(facts.checks.first { $0.id == "credentials" }?.status == .failed)
    }

    @Test("A linked asset whose availability has not been checked stays unverified")
    func unverifiedAsset() {
        var facts = StreamPreflightFacts()
        facts.sourceCount = 1
        facts.previewRunning = true
        facts.unverifiedSources = ["Image asset availability has not been verified."]
        #expect(facts.checks.first { $0.id == "sources" }?.status == .unverified)
    }

    @Test("Missing permissions, disconnected sources, muted mix, low disk and insufficient uplink are visible")
    func failures() {
        var facts = StreamPreflightFacts()
        facts.permissionIssues = ["Camera permission denied"]
        facts.sourceCount = 2
        facts.missingSources = ["Camera disconnected"]
        facts.previewRunning = true
        facts.programAudioPeak = 0
        facts.destinationCount = 1
        facts.destinationErrors = ["Missing stream key"]
        facts.profileErrors = ["Codec rejected"]
        facts.storageWritable = true
        facts.storageAvailableBytes = 100
        facts.encoderCount = 3
        facts.testedEncoderBudget = 2
        facts.requiredUplinkMbps = 8
        facts.measuredUplinkMbps = 4
        #expect(facts.checks.filter { $0.status == .failed }.count == 7)
        #expect(facts.checks.first { $0.id == "audio" }?.status == .warning)
    }

    @Test("An audible valid program with measured headroom passes each category")
    func valid() {
        var facts = StreamPreflightFacts()
        facts.sourceCount = 3
        facts.previewRunning = true
        facts.programAudioPeak = 0.1
        facts.destinationCount = 2
        facts.storageWritable = true
        facts.storageAvailableBytes = 5_000_000_000
        facts.encoderCount = 2
        facts.testedEncoderBudget = 3
        facts.requiredUplinkMbps = 10
        facts.measuredUplinkMbps = 15
        #expect(facts.checks.allSatisfy { $0.status == .passed })
    }

    @Test("Fixed publishing owners and real recording reservations share the four-encoder budget")
    func aggregateReservations() {
        var facts = StreamPreflightFacts()
        facts.encoderCount = 1; facts.recordingEncoderReservations = 3
        facts.sharedH264AAC = true; facts.testedEncoderBudget = 1
        let valid = facts.checks.first { $0.id == "encoders" }
        #expect(valid?.status == .passed)
        #expect(valid?.detail.contains("Fixed-profile H.264/AAC") == true)
        facts.recordingEncoderReservations = 4
        #expect(facts.checks.first { $0.id == "encoders" }?.status == .failed)
    }
}

private actor FakeUplink {
    var bytes = 0
    var count = 0
    var requestsSafe = true
    func upload(_ request: URLRequest, _ payload: Data) -> Int {
        requestsSafe = requestsSafe && request.url == UplinkProbe.endpoint &&
            request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil
        bytes += payload.count
        count += 1
        return 200
    }
}

@Suite struct UplinkProbeTests {
    @Test("Explicit measurement uploads only synthetic bounded payload, with no credential headers")
    func cap() async throws {
        let fake = FakeUplink()
        let probe = UplinkProbe(upload: { await fake.upload($0, $1) }, clock: { 0 })
        let result = try await probe.run()
        #expect(result.uploadedBytes == UplinkProbe.maximumPayloadBytes)
        #expect(await fake.bytes == UplinkProbe.maximumPayloadBytes)
        #expect(await fake.requestsSafe)
        #expect(result.megabitsPerSecond.isFinite)
    }

    @Test("A non-success HTTP response cannot be reported as measured capacity")
    func rejected() async {
        let probe = UplinkProbe(upload: { _, _ in 403 })
        await #expect(throws: (any Error).self) { _ = try await probe.run() }
    }

    @Test("Cancellation does not save or continue an upload")
    func cancellation() async {
        let task = Task {
            let probe = UplinkProbe(upload: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return 200
            })
            return try await probe.run()
        }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }
}

private final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}

@Suite struct UplinkDeadlineTests {
    @Test("A hard deadline retains only acknowledged bytes and includes the whole interval")
    func partialDeadline() async throws {
        let clock = ProbeClock()
        let probe = UplinkProbe(upload: { _, _ in
            clock.advance(5)
            if clock.read() >= 10 { throw URLError(.timedOut) }
            return 200
        }, clock: { clock.read() })
        let result = try await probe.run()
        #expect(result.uploadedBytes == 64 * 1024)
        #expect(result.duration == 10)
        #expect(result.megabitsPerSecond > 0 && result.megabitsPerSecond < 0.1)
    }
}
