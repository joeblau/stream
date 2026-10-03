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
        #expect(compatible.encoderSessions == 2, "Default adaptive mode reserves one encoder per publisher")
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

    @Test("Opt-in fixed H264 AAC sharing counts supported groups only")
    func fixedSharing() {
        let a = StreamDestination(name: "A", transport: .rtmp)
        var b = a.duplicated(); b.transport = .srt
        let raw = DestinationEncodingPlan(destinations: [a, b], program: .default)
        #expect(raw.encoderSessions == 2 && !raw.sharedH264AAC)
        let shared = DestinationEncodingPlan(destinations: [a, b], program: .default, measuredSessionLimit: 1, shareH264AAC: true)
        #expect(shared.encoderSessions == 1 && shared.issues.isEmpty)
        b.canvas = .secondary
        #expect(DestinationEncodingPlan(destinations: [a, b], program: .default, shareH264AAC: true).encoderSessions == 2)
        b = a; b.transport = .srt; b.audioBitrate += 1
        #expect(DestinationEncodingPlan(destinations: [a, b], program: .default, shareH264AAC: true).encoderSessions == 2)
        var whip = a.duplicated(); whip.transport = .whip
        let secondWhip = whip.duplicated()
        var hevc = a.duplicated(); hevc.transport = .srt; hevc.videoCodec = .hevc
        #expect(DestinationEncodingPlan(destinations: [a, whip, secondWhip, hevc, hevc.duplicated()], program: .default, shareH264AAC: true).encoderSessions == 5)
        for rate in [16_000, 640_000] {
            var unsupported = a; unsupported.audioBitrate = rate
            #expect(DestinationEncodingPlan(destinations: [unsupported, unsupported.duplicated()], program: .default, shareH264AAC: true).encoderSessions == 2)
        }
        var fractional = a; fractional.keyframeSeconds = 1.5
        #expect(DestinationEncodingPlan(destinations: [fractional, fractional.duplicated()], program: .default, shareH264AAC: true).encoderSessions == 2)
        var faster = a; faster.followsProgramProfile = false
        faster.outputProfile = .init(canvasWidth: 1280, canvasHeight: 720, frameRate: 60)
        #expect(DestinationEncodingPlan(destinations: [faster, faster.duplicated()], program: .default, shareH264AAC: true, sourceFrameRate: 24).encoderSessions == 2)
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
