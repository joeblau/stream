import Testing
import Foundation
import CoreGraphics
import StreamCore

/// Unit tests for the W07 output-profile model: even-pixel invariants, preset
/// coverage, the single-place capability gating (hardware + destination), and
/// the legacy-settings upgrade path.
@Suite struct OutputProfileTests {

    // MARK: - Invariants

    @Test("Odd dimensions are rounded down to even (H.264/HEVC requirement)")
    func evenPixelEnforcement() {
        let p = OutputProfile(canvasWidth: 1281, canvasHeight: 719, frameRate: 30)
        #expect(p.canvasWidth == 1280)
        #expect(p.canvasHeight == 718)
    }

    @Test("Dimensions never drop below 2 px and fps never below 1")
    func floors() {
        let p = OutputProfile(canvasWidth: 0, canvasHeight: 1, frameRate: 0)
        #expect(p.canvasWidth == 2)
        #expect(p.canvasHeight == 2)
        #expect(p.frameRate == 1)
    }

    @Test("Decoded profiles are re-normalized (hand-edited settings files)")
    func decodeNormalizes() throws {
        let p = try JSONDecoder().decode(
            OutputProfile.self,
            from: Data(#"{"canvasWidth": 1921, "canvasHeight": 1081, "frameRate": 0}"#.utf8))
        #expect(p.canvasWidth == 1920)
        #expect(p.canvasHeight == 1080)
        #expect(p.frameRate == 1)
    }

    @Test("Mutations rebuild through the initializer, keeping invariants")
    func withKeepsInvariants() {
        let p = OutputProfile.default.with(canvasWidth: 1001)
        #expect(p.canvasWidth == 1000)
        #expect(p.canvasHeight == OutputProfile.default.canvasHeight)
    }

    // MARK: - Presets

    @Test("The preset list covers landscape, portrait and square canvases")
    func presetCoverage() {
        #expect(CanvasPreset.landscape1080.size?.0 == 1920)
        #expect(CanvasPreset.portrait1080.size?.1 == 1920)
        #expect(CanvasPreset.square1080.size?.0 == CanvasPreset.square1080.size?.1)
        #expect(CanvasPreset.landscape4K.size?.0 == 3840)
    }

    @Test("A profile matching a preset resolves to it; anything else is custom")
    func presetMatching() {
        #expect(CanvasPreset(matching: OutputProfile(canvasWidth: 1920, canvasHeight: 1080, frameRate: 30)) == .landscape1080)
        #expect(CanvasPreset(matching: OutputProfile(canvasWidth: 1000, canvasHeight: 1000, frameRate: 30)) == .custom)
    }

    // MARK: - Hardware tiers

    @Test("4K requires Apple-Silicon-class signals (≥8 cores, ≥8 GB)")
    func hardware4KGate() {
        #expect(OutputCapabilities.hardware(processorCount: 8, physicalMemory: 8_000_000_000).hardwareTier == .uhd4K)
        #expect(OutputCapabilities.hardware(processorCount: 8, physicalMemory: 4_000_000_000).hardwareTier == .fullHD1080)
        #expect(OutputCapabilities.hardware(processorCount: 4, physicalMemory: 16_000_000_000).hardwareTier == .fullHD1080)
        #expect(OutputCapabilities.hardware(processorCount: 4, physicalMemory: 3_000_000_000).hardwareTier == .hd720)
    }

    @Test("60 fps needs the high memory + core floors, else 30")
    func hardwareFPSGate() {
        #expect(OutputCapabilities.hardware(processorCount: 8, physicalMemory: 8_000_000_000).hardwareMaxFrameRate == 60)
        #expect(OutputCapabilities.hardware(processorCount: 4, physicalMemory: 3_500_000_000).hardwareMaxFrameRate == 30)
    }

    // MARK: - Destination gating

    private let capable = OutputCapabilities(hardwareTier: .uhd4K, hardwareMaxFrameRate: 60)

    @Test("RTMP destinations gate 4K away with a human reason")
    func rtmpGates4K() {
        let p4k = OutputProfile(canvasWidth: 3840, canvasHeight: 2160, frameRate: 30)
        #expect(capable.gateReason(for: p4k, destination: .rtmps) != nil)
        #expect(capable.gateReason(for: p4k, destination: .srt) == nil)
    }

    @Test("WHIP gates 60 fps away; RTMP and SRT allow it")
    func whipGatesHighFPS() {
        let p60 = OutputProfile(canvasWidth: 1920, canvasHeight: 1080, frameRate: 60)
        #expect(capable.gateReason(for: p60, destination: .whip) != nil)
        #expect(capable.gateReason(for: p60, destination: .rtmp) == nil)
        #expect(capable.gateReason(for: p60, destination: .srt) == nil)
    }

    @Test("A weak device gates by hardware even when the destination allows more")
    func hardwareGatesFirst() {
        let weak = OutputCapabilities(hardwareTier: .hd720, hardwareMaxFrameRate: 30)
        let p1080 = OutputProfile(canvasWidth: 1920, canvasHeight: 1080, frameRate: 24)
        let reason = weak.gateReason(for: p1080, destination: .srt)
        #expect(reason != nil)
        #expect(reason?.contains("720p") == true)
    }

    @Test("Vertical and square canvases fit the tier box by both edges")
    func tierFitsOrientations() {
        #expect(OutputCapabilities.ResolutionTier.fullHD1080.fits(width: 1080, height: 1920))
        #expect(OutputCapabilities.ResolutionTier.fullHD1080.fits(width: 1080, height: 1080))
        #expect(!OutputCapabilities.ResolutionTier.hd720.fits(width: 1080, height: 1920))
    }

    @Test("Clamping reduces resolution aspect-preserving and caps fps")
    func clampReduces() {
        let p = OutputProfile(canvasWidth: 3840, canvasHeight: 2160, frameRate: 60)
        let clamped = capable.clamped(p, destination: .whip)
        #expect(clamped.canvasWidth == 1920)
        #expect(clamped.canvasHeight == 1080)
        #expect(clamped.frameRate == 30)
        #expect(capable.gateReason(for: clamped, destination: .whip) == nil)
    }

    // MARK: - Settings persistence / upgrade

    @Test("Settings blobs predating W07 derive the profile from videoQuality + frameRate")
    func legacySettingsDeriveProfile() throws {
        let s = try JSONDecoder().decode(
            StreamSettings.self,
            from: Data(#"{"videoQuality": 1080, "frameRate": 30}"#.utf8))
        #expect(s.outputProfile.canvasWidth == 1920)
        #expect(s.outputProfile.canvasHeight == 1080)
        #expect(s.outputProfile.frameRate == 30)
    }

    @Test("An explicit profile round-trips through settings encode/decode")
    func profileRoundTrips() throws {
        var original = StreamSettings.default
        original.outputProfile = OutputProfile(canvasWidth: 1080, canvasHeight: 1920, frameRate: 50)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(restored.outputProfile == original.outputProfile)
        #expect(restored == original)
    }
}
