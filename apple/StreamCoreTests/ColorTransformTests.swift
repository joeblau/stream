import Foundation
import Testing
import StreamCore

@Suite struct ColorTransformTests {
    private func cube(_ rows: [String]? = nil) -> Data {
        let rgb = rows ?? (0..<8).map { i in "\(i%2) \((i/2)%2) \(i/4)" }
        return Data((["TITLE \"Identity\"", "LUT_3D_SIZE 2", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]+rgb).joined(separator: "\n").utf8)
    }
    @Test func cubeOrderingIntensityAndPremultipliedAlpha() throws {
        let lut = try CubeLUT.parse(cube())
        #expect(lut.dimension == 2 && lut.title == "Identity")
        #expect(lut.values[1] == SIMD3(1,0,0))
        #expect(lut.values[2] == SIMD3(0,1,0))
        #expect(lut.values[4] == SIMD3(0,0,1))
        let identity = try #require(lut.rgbaData(intensity: 0))
        #expect(identity == lut.rgbaData(intensity: 1))
        #expect(identity.count == 8*4*MemoryLayout<Float>.size)
        #expect(lut.rgbaData(intensity: .nan) == nil)
        let black = try CubeLUT.parse(cube(Array(repeating: "0 0 0",count: 8)))
        let half = try #require(black.rgbaData(intensity: 0.5))
        let components = half.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(Array(components.suffix(4)) == [0.5,0.5,0.5,1])
    }
    @Test func cubeRejectsMalformedAndUnsupportedFiles() {
        for text in ["LUT_1D_SIZE 16", "LUT_3D_SIZE 65", "LUT_3D_SIZE 1", "LUT_3D_SIZE 2\n0 0 0",
                     "LUT_3D_SIZE 2\nDOMAIN_MIN -1 0 0", "LUT_3D_SIZE 2\nNaN 0 0",
                     "LUT_3D_SIZE 2\nLUT_3D_SIZE 2", "LUT_3D_INPUT_RANGE 0 1",
                     "LUT_3D_SIZE 2\n1.01 0 0"] {
            #expect(throws: CubeLUT.Failure.self) { try CubeLUT.parse(Data(text.utf8)) }
        }
        #expect(throws: CubeLUT.Failure.self) { try CubeLUT.parse(cube(Array(repeating: "0 0 0",count: 9))) }
        #expect(throws: CubeLUT.Failure.self) { try CubeLUT.parse(Data([0xff,0xfe])) }
        #expect(throws: CubeLUT.Failure.self) { try CubeLUT.parse(Data(repeating: 32,count: CubeLUT.maxFileBytes+1)) }
    }
    @Test func cubeAcceptsCommentsWhitespaceBOMAndScientificNotation() throws {
        var text = String(data: cube(),encoding: .utf8)!
        text = "\u{FEFF}# comment\n" + text.replacingOccurrences(of:"1 0 0",with:"1e0\t0.0 0 # red")
        #expect(try CubeLUT.parse(Data(text.utf8)).values[1] == SIMD3(1,0,0))
    }
    @Test func greenBlueCustomNeutralAndBypass() {
        var key = ChromaKeySettings(); key.isEnabled = true
        #expect(ChromaKeyTransform.rgba(SIMD3(0,1,0), settings:key) == .zero)
        #expect(ChromaKeyTransform.rgba(SIMD3(1,0,0), settings:key).w == 1)
        #expect(ChromaKeyTransform.rgba(SIMD3(0,0.6,0), settings:key) == .zero)
        #expect(ChromaKeyTransform.rgba(SIMD3(0.98,1,0.98), settings:key).w > 0.99)
        key.keyColorHex = "#0000FF"
        #expect(ChromaKeyTransform.rgba(SIMD3(0,0,1), settings:key) == .zero)
        #expect(ChromaKeyTransform.rgba(SIMD3(0,1,0), settings:key).w == 1)
        key.keyColorHex = "#000000"
        #expect(ChromaKeyTransform.rgba(.zero, settings:key) == .zero)
        #expect(ChromaKeyTransform.rgba(SIMD3(repeating: 1), settings:key).w == 1)
        key.isBypassed = true
        #expect(ChromaKeyTransform.rgba(SIMD3(0,1,0),inputAlpha:0.4,settings:key) == SIMD4(0,0.4,0,0.4))
    }
    @Test func softnessSpillAndExistingAlpha() {
        var settings = ChromaKeySettings(); settings.isEnabled = true
        settings.tolerance = 0.01; settings.softness = 0.5; settings.spill = 0
        let rgb = SIMD3<Double>(0.1,0.6,0.1)
        let edge = ChromaKeyTransform.rgba(rgb,settings:settings)
        #expect(edge.w > 0 && edge.w < 1)
        let transparent = ChromaKeyTransform.rgba(rgb,inputAlpha:0.2,settings:settings)
        #expect(abs(transparent.w - edge.w*0.2) < 0.000001)
        #expect(ChromaKeyTransform.rgba(rgb,inputAlpha:0,settings:settings) == .zero)
        settings.spill = 1
        let cleaned = ChromaKeyTransform.rgba(rgb,settings:settings)
        #expect(cleaned.w == edge.w)
        #expect(cleaned.y/cleaned.w < edge.y/edge.w)
        #expect(cleaned.x/cleaned.w > edge.x/edge.w)
    }
    @Test func controlsValidationAndCubeDimensions() throws {
        var settings = ChromaKeySettings()
        #expect(settings.validationError == nil)
        settings.left = 0.7; settings.right = 0.4
        #expect(settings.validationError != nil)
        #expect(ChromaKeyTransform.cubeData(settings:settings,dimension:2) == nil)
        settings = ChromaKeySettings(); settings.isEnabled = true
        let data = try #require(ChromaKeyTransform.cubeData(settings:settings,dimension:2))
        #expect(data.count == 8*4*4)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
        #expect(Array(floats[8..<12]) == [0,0,0,0], "Green texel must have premultiplied zero alpha")
        #expect(ChromaKeyTransform.cubeData(settings:settings,dimension:65) == nil)
        settings.keyColorHex = "#zzzzzz"; #expect(settings.validationError != nil)
        settings = ChromaKeySettings(); settings.softness = .nan; #expect(settings.validationError != nil)
        var lut = LUTSettings(); lut.intensity = .infinity; #expect(lut.validationError != nil)
    }
}
