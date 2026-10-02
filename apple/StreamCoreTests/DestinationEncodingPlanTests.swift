import Foundation
import Testing
@testable import StreamCore

@Suite struct DestinationEncodingPlanTests {
    @Test("Compatibility includes geometry, fps, codec, bitrate, keyframes and audio packetization")
    func compatibility() {
        let primary = StreamDestination(name: "Primary")
        var copy = primary.duplicated()
        copy.isEnabled = true
        let compatible = DestinationEncodingPlan(destinations: [primary, copy], program: .default)
        #expect(compatible.compatibleGroups.count == 1)
        #expect(compatible.encoderSessions == 2, "Current backend does not share hardware sessions")
        let baseline = DestinationEncoderKey(destination: primary, program: .default)
        copy.videoBitrate += 1
        #expect(DestinationEncoderKey(destination: copy, program: .default) != baseline)
        copy = primary; copy.transport = .whip
        #expect(DestinationEncoderKey(destination: copy, program: .default) != baseline)
        copy = primary; copy.keyframeSeconds = 1
        #expect(DestinationEncoderKey(destination: copy, program: .default) != baseline)
        copy = primary; copy.followsProgramProfile = false
        copy.outputProfile = .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 60)
        #expect(DestinationEncoderKey(destination: copy, program: .default) != baseline)
    }

    @Test("Aggregate estimates enforce ten outputs and measured session/uplink limits")
    func estimates() {
        let targets = (0..<10).map { StreamDestination(name: "Destination \($0)", videoBitrate: 4_000_000, audioBitrate: 128_000) }
        let valid = DestinationEncodingPlan(destinations: targets, program: .default, measuredUplinkMbps: 60, measuredSessionLimit: 10)
        #expect(valid.issues.isEmpty)
        #expect(valid.aggregateBitrate == 41_280_000)
        #expect(abs(valid.requiredUplinkMbps - 55.728) < 0.0001)
        let invalid = DestinationEncodingPlan(destinations: targets + [targets[0].duplicated()], program: .default,
                                               measuredUplinkMbps: 10, measuredSessionLimit: 4)
        #expect(invalid.issues.count == 3)
    }

    @Test("Explicit ingest overrides are isolated and never bypass packetizer/hardware capability")
    func limits() {
        var destination = StreamDestination(name: "Enhanced", transport: .rtmps, followsProgramProfile: false,
            outputProfile: .init(canvasWidth: 3840, canvasHeight: 2160, frameRate: 60), videoCodec: .hevc)
        let credentials = DestinationCredentials(endpoint: "rtmps://host/live", streamKey: "secret")
        let hardware = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)
        #expect(!DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: hardware).isEmpty)
        destination.ingestLimits = .init(source: .validatedIngest, maxWidth: 3840, maxHeight: 2160, maxFrameRate: 60,
                                          codecs: [.h264, .hevc])
        #expect(DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: hardware).isEmpty)
        destination.transport = .whip
        destination.outputProfile = .default
        #expect(DestinationValidator.startErrors(destination, credentials: .init(endpoint: "https://host/whip"),
            program: .default, capabilities: hardware).contains { $0.contains("does not support") })
        destination.transport = .rtmps
        destination.outputProfile = .init(canvasWidth: 3840, canvasHeight: 2160, frameRate: 60)
        let weak = OutputCapabilities(hardwareTier: .hd720, hardwareMaxFrameRate: 30)
        #expect(DestinationValidator.startErrors(destination, credentials: credentials, program: .default, capabilities: weak).contains { $0.contains("hardware") })
    }

    @Test("Keyframe constraints reach the publisher adapter and old snapshots default safely")
    func keyframes() throws {
        var destination = StreamDestination(name: "One second")
        destination.keyframeSeconds = 1
        let output = DestinationValidator.settings(destination, credentials: .init(), base: .default)
        #expect(output.destinationKeyframeSeconds == 1)
        #expect(try JSONDecoder().decode(StreamSettings.self, from: Data("{}".utf8)).destinationKeyframeSeconds == nil)
        destination.keyframeSeconds = 0.5
        #expect(DestinationValidator.errors(destination, credentials: .init()).contains { $0.contains("whole number") })
    }
}

@Suite struct ProgramCanvasIsolationTests {
    @Test("A lower-resolution RTMP destination cannot lower a 4K local program canvas")
    func programRemains4K() {
        let capabilities = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)
        let program = OutputProfile(canvasWidth: 3840, canvasHeight: 2160, frameRate: 60)
        #expect(capabilities.clampedToHardware(program) == program)
        #expect(capabilities.hardwareGateReason(for: program) == nil)
        #expect(capabilities.gateReason(for: program, destination: .rtmps) != nil)
        let destination = StreamDestination(name: "HD endpoint", followsProgramProfile: false,
            outputProfile: .init(canvasWidth: 1920, canvasHeight: 1080, frameRate: 30))
        #expect(destination.effectiveProfile(program: program) != program)
        #expect(capabilities.clampedToHardware(program) == program)
    }
}
