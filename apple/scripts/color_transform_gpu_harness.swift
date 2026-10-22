import Foundation
import Darwin
import CryptoKit
import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import StreamCore

/// Runs shipping filters and SceneRenderer on a real Metal context. Analytical
/// pixel controls complement the independent, photographed temporal sequence.
enum ColorGPUQualification {
    final class Pixels: @unchecked Sendable { let buffer: CVPixelBuffer; init(_ value: CVPixelBuffer) { buffer = value } }
    static let videoBackgroundID = SourceDefinitionID()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ColorGPUQualification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func read(_ image: CIImage, context: CIContext, space: CGColorSpace = srgb) -> [Float] {
        let rect = image.extent.integral
        var data = [Float](repeating: 0, count: Int(rect.width * rect.height) * 4)
        context.render(image, toBitmap: &data, rowBytes: Int(rect.width) * 16, bounds: rect, format: .RGBAf, colorSpace: space)
        return data
    }
    static func image(_ colors: [SIMD4<Float>], width: Int, height: Int) -> CIImage {
        let data = colors.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: srgb)
    }
    static func pixels(_ image: CIImage, context: CIContext) throws -> Pixels {
        var value: CVPixelBuffer?
        let size = image.extent.integral.size
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        try require(status == kCVReturnSuccess && value != nil, "Could not allocate photographed source pixels")
        CVBufferSetAttachment(value!, kCVImageBufferCGColorSpaceKey, srgb, .shouldPropagate)
        context.render(image, to: value!, bounds: image.extent, colorSpace: srgb)
        return Pixels(value!)
    }
    static func warm(_ settings: ChromaKeySettings) async throws {
        for _ in 0..<500 {
            if ColorCubeCache.shared.chroma(settings) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ColorGPUQualification", code: 2)
    }
    static func lut(_ values: [SIMD3<Float>], dimension: Int, intensity: Double = 1, colorSpace: LUTColorSpace = .sRGB) async throws -> LUTSettings {
        let rows = values.map { "\($0.x) \($0.y) \($0.z)" }
        let cube = try CubeLUT.parse(Data((["LUT_3D_SIZE \(dimension)"] + rows).joined(separator: "\n").utf8))
        let entry = LUTTableStore.Entry(generation: UUID(), cube: cube), id = AssetID()
        LUTTableStore.shared.set(entry, for: id)
        for _ in 0..<500 {
            if ColorCubeCache.shared.lut(entry, intensity: intensity, colorSpace: colorSpace) != nil {
                var value = LUTSettings(); value.assetID = id; value.intensity = intensity; value.colorSpace = colorSpace; return value
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ColorGPUQualification", code: 3)
    }
    static func render(_ renderer: SceneRenderer, source: Pixels, effects: SourceEffects, background: CIImage?, videoBackground: Pixels? = nil,
                       sequence: Int64 = 0, size: CGSize? = nil) throws -> CompositedFrame {
        var layer = LayerNode(name: "Photographed source", payload: .camera(.init(deviceID: "fixture-decoded-plate")), transform: .fullscreen)
        layer.effectOverrides = effects
        var layers: [LayerNode] = []
        if background != nil { layers.append(.init(name: "Image background", payload: .image(.init()), transform: .fullscreen)) }
        if videoBackground != nil { layers.append(.init(name: "Video background", sourceID: videoBackgroundID, payload: .media(.init(assetIdentifier: "fixture-decoded-background")), transform: .fullscreen)) }
        layers.append(layer)
        let scene = Scene(name: "Metal color qualification", layers: layers)
        let lookup = SourceFrameLookup(camera: { _ in .init(buffer: source.buffer, position: .back) }, screen: { _ in nil }, media: { key in key == .media(videoBackgroundID) ? videoBackground?.buffer : nil })
        let canvas = size ?? CGSize(width: CVPixelBufferGetWidth(source.buffer), height: CVPixelBufferGetHeight(source.buffer))
        guard let result = renderer.render(scene: scene, overlayContext: .empty, canvasSize: canvas,
            frames: lookup, sourcePayloads: videoBackground == nil ? [:] : [videoBackgroundID: .media(.init(assetIdentifier: "fixture-decoded-background"))], scenes: [:], presentationTime: CMTime(value: sequence, timescale: 30),
            frameDuration: CMTime(value: 1, timescale: 30), sequence: sequence) else {
            throw NSError(domain: "ColorGPUQualification", code: 4, userInfo: [NSLocalizedDescriptionKey: "Shipping Metal renderer dropped a frame"])
        }
        return result
    }
    static func run(directory: URL, context: CIContext, device: MTLDevice) async throws {
        print("Metal qualification device: \(device.name); no software renderer fallback")
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let gray = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 0.5)).cropped(to: rect)
        let settings = try await lut(Array(repeating: SIMD3<Float>(repeating: 0.25), count: 8), dimension: 2)
        let linearSettings = try await lut(Array(repeating: SIMD3<Float>(repeating: 0.25), count: 8), dimension: 2, colorSpace: .linearSRGB)
        let encoded = read(ColorTransformRenderer.lut(settings, image: gray), context: context)
        let linearOutput = read(ColorTransformRenderer.lut(linearSettings, image: gray), context: context)
        print("Color-space control premultiplied sRGB \(encoded.prefix(4)), linear-sRGB \(linearOutput.prefix(4))")
        try require(abs(encoded[0] - 0.125) < 0.004 && abs(encoded[3] - 0.5) < 0.004, "sRGB LUT did not preserve encoded color/alpha")
        try require(abs(linearOutput[0] - 0.26855) < 0.004 && abs(linearOutput[3] - 0.5) < 0.004, "Linear-sRGB LUT color space was ignored or applied twice")
        let half = try await lut(Array(repeating: SIMD3<Float>(repeating: 0.25), count: 8), dimension: 2, intensity: 0.5)
        let halfOutput = read(ColorTransformRenderer.lut(half, image: gray), context: context)
        try require(abs(halfOutput[0] - 0.2125) < 0.004, "LUT intensity did not blend identity in its declared color space")
        var bypass = settings; bypass.isBypassed = true
        try require(read(ColorTransformRenderer.lut(bypass, image: gray), context: context) == read(gray, context: context), "LUT bypass modified color or alpha")
        var identityRows: [SIMD3<Float>] = []
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { identityRows.append(.init(Float(r), Float(g), Float(b))) } } }
        let linearIdentity = try await lut(identityRows, dimension: 2, colorSpace: .linearSRGB)
        for component: CGFloat in [0.01, 0.02, 0.04, 0.1, 0.2, 0.5, 0.9] {
            let shadow = CIImage(color: CIColor(red: component, green: component, blue: component, alpha: 0.5)).cropped(to: rect)
            let transformed = read(ColorTransformRenderer.lut(linearIdentity, image: shadow), context: context)
            try require(abs(transformed[0] - Float(component)*0.5) < 0.004 && abs(transformed[3]-0.5) < 0.004,
                        "Linear identity LUT crushed shadow detail or changed alpha")
        }
        let capturedGray = try pixels(gray, context: context)
        for (configuration, expected) in [(settings, Float(0.125)), (linearSettings, Float(0.26855))] {
            var stack = SourceEffects(); stack.lut = configuration
            let frame = try render(SceneRenderer(), source: capturedGray, effects: stack, background: nil)
            let result = read(CIImage(cvPixelBuffer: frame.pixelBuffer!), context: context)
            try require(abs(result[0] - expected) < 0.008 && abs(result[3] - 1) < 0.008,
                        "Actual SceneRenderer did not honor LUT color-space/alpha over its canvas")
        }
        print("PASS: actual Metal nonlinear color-space discrimination, half intensity and fractional-alpha bypass, including shipping SceneRenderer")
        try await compositionControls(context: context)
        if let path = ProcessInfo.processInfo.environment["COLOR_FOOTAGE_DIRECTORY"] {
            try await photographedSequence(URL(fileURLWithPath: path), directory: directory, context: context, device: device)
        } else {
            print("NOT RUN: representative-footage and sustained qualification; set COLOR_FOOTAGE_DIRECTORY after running fetch_color_qualification_footage.py")
        }
        print("NOT QUALIFIED: a live physical camera source was not opened; no camera/microphone/TCC grants were requested")
    }
}

extension ColorGPUQualification {
    static func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
    static func compositionControls(context: CIContext) async throws {
        let width = 96, height = 64, bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var samples: [SIMD4<Float>] = []
        for y in 0..<height { for x in 0..<width {
            let color: SIMD4<Float> = x < width / 2 ? .init(0, 1, 0, 1) : .init(Float(x) / Float(width), 0.15, Float(y) / Float(height), 1)
            samples.append(color)
        } }
        let sourceImage = image(samples, width: width, height: height), source = try pixels(sourceImage, context: context)
        let blue = CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.8)).cropped(to: bounds)
        var effects = SourceEffects(); effects.chromaKey.isEnabled = true
        effects.chromaKey.left = 0.08; effects.chromaKey.top = 0.12; effects.chromaKey.maskFeather = 1.5
        effects.isMirrored = true; effects.brightness = 0.11; effects.gamma = 0.8
        try await warm(effects.chromaKey)
        var mask = effects.chromaKey; mask.left = 0.25; mask.top = 0.25; mask.maskFeather = 0
        let masked = read(ColorTransformRenderer.key(mask, image: CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.4)).cropped(to: bounds)), context: context)
        let alphaAt = { (x: Int, y: Int) in masked[(y * width + x) * 4 + 3] }
        try require(alphaAt(width / 8, height / 2) < 0.005 && alphaAt(width / 2, height / 8) < 0.005 && abs(alphaAt(width / 2, height / 2)-0.4) < 0.005,
                    "Source-space garbage mask reversed top/bottom, left/right, or existing fractional alpha")
        var rows: [SIMD3<Float>] = []
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { rows.append(.init(Float(r) * 0.25, Float(g) * 0.6, Float(b) * 0.8)) } } }
        effects.lut = try await lut(rows, dimension: 2)
        let renderer = SceneRenderer(imageProvider: { _ in blue })
        let output = try render(renderer, source: source, effects: effects, background: blue)
        let actual = read(CIImage(cvPixelBuffer: output.pixelBuffer!), context: context)
        let raw = CIImage(cvPixelBuffer: source.buffer)
        let key = ColorTransformRenderer.key(effects.chromaKey, image: raw)
        let framed = key.oriented(.upMirrored)
        let adjusted = framed.applyingFilter("CIColorControls", parameters: ["inputBrightness": effects.brightness, "inputContrast": 1, "inputSaturation": 1])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": effects.gamma])
        let expected = read(ColorTransformRenderer.lut(effects.lut, image: adjusted).composited(over: blue), context: context)
        try require(maxDifference(actual, expected) < 0.025, "Shipping compositor changed key/mask → framing → picture → LUT → background order or alpha")
        let reversed = ColorTransformRenderer.key(effects.chromaKey, image: ColorTransformRenderer.lut(effects.lut, image: raw))
        try require(maxDifference(read(reversed, context: context), read(key, context: context)) > 0.2, "Order fixture's transform accidentally commutes with keying")
        // Whole-stack bypass also skips source-space masks/framing, not just LUT.
        effects.isBypassed = true
        let bypassed = try render(renderer, source: source, effects: effects, background: blue)
        let identity = try render(renderer, source: source, effects: .identity, background: blue)
        try require(read(CIImage(cvPixelBuffer: bypassed.pixelBuffer!), context: context) == read(CIImage(cvPixelBuffer: identity.pixelBuffer!), context: context), "Whole-stack bypass lost framing/color/alpha identity")
        // The same keyed alpha must reveal pixels pulled through the MEDIA path.
        effects.isBypassed = false
        let video = try pixels(blue, context: context)
        let videoOutput = try render(renderer, source: source, effects: effects, background: nil, videoBackground: video)
        let videoActual = read(CIImage(cvPixelBuffer: videoOutput.pixelBuffer!), context: context)
        let difference = maxDifference(videoActual, actual)
        try require(difference < 0.025, "Keyed alpha differs over image and video background paths")
        try require(renderer.kernelMetrics.backend.contains("Metal"), "Production renderer silently selected software")
        print("PASS: shipping Metal SceneRenderer key/garbage-mask before mirror, picture before noncommuting LUT, image/video backgrounds, alpha and complete-stack bypass")
    }
    struct Manifest: Decodable {
        struct Frame: Decodable { let file: String; let bytes: Int; let sha256: String; let url: String }
        let credit: String; let license: String; let source: String; let color: String; let frames: [Frame]
    }
    struct TemporalReading: Codable {
        let frame: String
        let hairFractionalSamples: Int
        let alphaMeanAbsoluteError: Double
        let alpha99thPercentileError: Double
        let hairAlpha99thPercentileError: Double
        let temporalMeanAbsoluteError: Double?
    }
    static func photographedSequence(_ folder: URL, directory: URL, context: CIContext, device: MTLDevice) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        try require(manifest.frames.count == 48 && manifest.license == "https://creativecommons.org/licenses/by/3.0/", "Pinned licensed48-frame sequence required")
        print("Photographed footage: \(manifest.credit), \(manifest.license), \(manifest.source)"); fflush(nil)
        try "\(manifest.credit)\n\(manifest.license)\nOriginal plates: \(manifest.source)\nChanges: decoded, clipped scene-linear SDR to encoded sRGB, chroma-keyed, composited and/or LUT-transformed for this qualification.\n".write(to: directory.appendingPathComponent("ATTRIBUTION.txt"), atomically: true, encoding: .utf8)
        var key = ChromaKeySettings(); key.isEnabled = true
        try await warm(key)
        var noSpill = key; noSpill.spill = 0
        try await warm(noSpill)
        var fullSpill = key; fullSpill.spill = 1
        try await warm(fullSpill)
        var decoded: [Pixels] = [], readings: [TemporalReading] = []
        var previousAlpha: [Float]?, previousReference: [Double]?
        var alphaError = 0.0, alphaCount = 0, temporalMotion = 0.0, spillReduction = 0.0, spillSamples = 0
        let readStarted = Date()
        for (index, frame) in manifest.frames.enumerated() {
            try autoreleasepool {
                let url = folder.appendingPathComponent(frame.file), data = try Data(contentsOf: url)
                let expectedURL = "https://media.xiph.org/tearsofsteel/tearsofsteel-footage-exr/04_2a/linear_hd/" + frame.file
                try require(url.lastPathComponent == frame.file && frame.url == expectedURL && data.count == frame.bytes,
                            "Unexpected footage source or byte count")
                try require(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == frame.sha256, "Footage hash mismatch: \(frame.file)")
                guard let photograph = CIImage(contentsOf: url, options: [.colorSpace: linear]) else {
                    throw NSError(domain: "ColorGPUQualification", code: 5, userInfo: [NSLocalizedDescriptionKey: "EXR decode failed"])
                }
                // Original camera plates are scene-linear Rec.709. The product
                // supports SDR .cube/key math; convert the decoded plate to an
                // explicitly clipped SDR sRGB derivative before simulating its
                // BGRA capture buffer. No generated green backdrop or matte.
                let bounded = photograph.applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                    .applyingFilter("CILinearToSRGBToneCurve")
                let source = try pixels(bounded, context: context); decoded.append(source)
                let sourceImage = CIImage(cvPixelBuffer: source.buffer), bounds = sourceImage.extent
                let width = Int(bounds.width), height = Int(bounds.height)
                try require(width == 1920 && height == 1012, "Original HD plate geometry changed")
                let before = read(sourceImage, context: context)
                let keyedImage = ColorTransformRenderer.key(key, image: sourceImage), keyed = read(keyedImage, context: context)
                let cleaned = read(ColorTransformRenderer.key(fullSpill, image: sourceImage), context: context)
                let uncleaned = read(ColorTransformRenderer.key(noSpill, image: sourceImage), context: context)
                var errors: [Double] = [], hairErrors: [Double] = [], alphas: [Float] = [], reference: [Double] = [], hairFractional = 0
                var transparent = 0, opaque = 0
                // Independent analytic oracle is sampled on photographed
                // pixels; it does not create or replace the photographed edges.
                for y in stride(from: 0, to: height, by: 4) { for x in stride(from: 0, to: width, by: 4) {
                    let offset = (y * width + x) * 4
                    let rgb = SIMD3<Double>(Double(before[offset]), Double(before[offset+1]), Double(before[offset+2]))
                    let expected = ChromaKeyTransform.rgba(rgb, settings: key)
                    let actual = Double(keyed[offset+3]), error = abs(actual - expected.w)
                    errors.append(error); alphas.append(Float(actual)); reference.append(expected.w)
                    try require(actual.isFinite && actual >= -0.001 && actual <= 1.001, "Nonfinite/out-of-range photographic alpha")
                    for channel in 0..<3 { try require(keyed[offset+channel] >= -0.002 && keyed[offset+channel] <= keyed[offset+3] + 0.006, "Photographed output lost premultiplied alpha") }
                    if actual < 0.02 { transparent += 1 }; if actual > 0.98 { opaque += 1 }
                    if x > width * 52 / 100 && x < width * 84 / 100 && y > height * 4 / 100 && y < height * 44 / 100 {
                        hairErrors.append(error)
                        if actual > 0.03 && actual < 0.97 { hairFractional += 1 }
                    }
                    if actual > 0.05 && actual < 0.95 {
                        let a = max(0.01, uncleaned[offset+3]), b = max(0.01, cleaned[offset+3])
                        let excess = max(0, (uncleaned[offset+1] - max(uncleaned[offset], uncleaned[offset+2])) / a)
                        let suppressed = max(0, (cleaned[offset+1] - max(cleaned[offset], cleaned[offset+2])) / b)
                        if excess > 0.02 { spillReduction += Double(excess - suppressed); spillSamples += 1 }
                        try require(abs(uncleaned[offset+3] - cleaned[offset+3]) < 0.015, "Spill changed the photographic matte")
                    }
                } }
                errors.sort()
                let mean = errors.reduce(0,+) / Double(errors.count), p99 = errors[min(errors.count-1, Int(Double(errors.count)*0.99))]
                hairErrors.sort()
                let hairP99 = hairErrors[min(hairErrors.count-1, Int(Double(hairErrors.count)*0.99))]
                // A64³ cube approximates steep chroma transitions in near-black
                // pixels. Bound overall error, with the tighter hair-region
                // bound that this photographed qualification actually targets.
                try require(mean < 0.025 && p99 < 0.25 && hairP99 < 0.10, "Metal photographed matte diverges from independent chroma oracle: \(mean), p99\(p99), hairp99\(hairP99)")
                try require(hairFractional > 10 && opaque > 1000 && transparent > 1000, "Photographed hair/foreground/background detail was flattened: \(frame.file), hair\(hairFractional)")
                var temporal: Double?
                if let previousAlpha, let previousReference {
                    let gpuDelta = zip(alphas, previousAlpha).map { Double($0-$1) }
                    let cpuDelta = zip(reference, previousReference).map(-)
                    temporal = zip(gpuDelta,cpuDelta).map { abs($0-$1) }.reduce(0,+) / Double(gpuDelta.count)
                    temporalMotion += cpuDelta.map(abs).reduce(0,+) / Double(cpuDelta.count)
                    try require(temporal! < 0.035, "Metal key introduced temporal edge error beyond input motion")
                }
                previousAlpha = alphas; previousReference = reference
                alphaError += errors.reduce(0,+); alphaCount += errors.count
                readings.append(.init(frame: frame.file, hairFractionalSamples: hairFractional, alphaMeanAbsoluteError: mean, alpha99thPercentileError: p99, hairAlpha99thPercentileError: hairP99, temporalMeanAbsoluteError: temporal))
                if [0, 23, 47].contains(index) {
                    let suffix = String(format: "%02d", index)
                    try ColorTransformHarness.save(ColorTransformHarness.bytes(sourceImage, context: context, rect: bounds), width: width, height: height, to: directory.appendingPathComponent("footage-\(suffix)-before.png"))
                    try ColorTransformHarness.save(ColorTransformHarness.bytes(keyedImage, context: context, rect: bounds), width: width, height: height, to: directory.appendingPathComponent("footage-\(suffix)-keyed.png"))
                    let bg = CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.8)).cropped(to: bounds)
                    let renderer = SceneRenderer(imageProvider: { _ in bg })
                    var effects = SourceEffects(); effects.chromaKey = key
                    let result = try render(renderer, source: source, effects: effects, background: bg)
                    let actual = read(CIImage(cvPixelBuffer: result.pixelBuffer!), context: context)
                    let expected = read(keyedImage.composited(over: bg), context: context)
                    try require(maxDifference(actual,expected) < 0.03, "Shipping renderer lost photographed transparency/background composition")
                    try ColorTransformHarness.save(ColorTransformHarness.bytes(CIImage(cvPixelBuffer: result.pixelBuffer!), context: context, rect: bounds), width: width, height: height, to: directory.appendingPathComponent("footage-\(suffix)-composite.png"))
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(readings).write(to: directory.appendingPathComponent("photographed-edge-measurements.json"))
        try require(temporalMotion > 0.02, "Footage fixture does not exercise real temporal matte movement")
        // Require a measurable positive change, not an invented artistic
        // percentage; the actual reduction is retained in the run report.
        try require(spillSamples > 100 && spillReduction / Double(spillSamples) > 0.001, "Spill suppression did not reduce measured photographic green contamination: samples\(spillSamples), reduction\(spillReduction / Double(max(1,spillSamples)))")
        print("PASS:48 hashed original1920×1012 photographed frames, real hair-edge fractional alpha (min\(readings.map(\.hairFractionalSamples).min() ?? 0)), mean alpha error\(alphaError / Double(alphaCount)), temporal motion\(temporalMotion), spill reduction\(spillReduction / Double(spillSamples)); decode+analysis\(Date().timeIntervalSince(readStarted))s")
        if let raw = ProcessInfo.processInfo.environment["COLOR_SUSTAIN_SECONDS"], let seconds = Double(raw), seconds >= 10 && seconds <= 300 {
            if let path = ProcessInfo.processInfo.environment["COLOR_QUIET_GATE_FILE"] {
                print("READY_FOR_QUIET_MEASUREMENT: photographed frames decoded and functional checks passed; waiting for \(path)"); fflush(nil)
                for _ in 0..<1200 {
                    if FileManager.default.fileExists(atPath: path) { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                try require(FileManager.default.fileExists(atPath: path), "Quiet-host measurement gate timed out")
            }
            try await sustained(decoded, key: key, context: context, seconds: seconds, directory: directory, device: device)
        } else {
            print("NOT RUN: sustained render cost; set COLOR_SUSTAIN_SECONDS=60 for paired paced1080p30 measurements")
        }
    }
    static func sustained(_ frames: [Pixels], key: ChromaKeySettings, context: CIContext, seconds: Double, directory: URL, device: MTLDevice) async throws {
        struct Measurement: Codable {
            let name: String
            let frames: Int
            let elapsedSeconds: Double
            let canvasWidth: Int
            let canvasHeight: Int
            let framesPerSecond: Int
            let renderMeanMilliseconds: Double
            let render95thMilliseconds: Double
            let render99thMilliseconds: Double
            let renderMaximumMilliseconds: Double
            let renderBudgetMisses: Int
            let cadenceMisses: Int
            let kernel: CompositionKernelMetrics
            let qualifies1080p30OnThisRun: Bool
        }
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let background = CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.8)).cropped(to: bounds)
        var effects = SourceEffects(); effects.chromaKey = key
        effects.chromaKey.left = 0.01; effects.chromaKey.maskFeather = 2
        effects.zoom = 1.05; effects.isMirrored = true; effects.brightness = 0.04; effects.gamma = 1.03
        var rows: [SIMD3<Float>] = []
        for b in 0..<64 { for g in 0..<64 { for r in 0..<64 { rows.append(.init(Float(r) / 63 * 0.9 + 0.03, Float(g) / 63 * 0.95 + 0.02, Float(b) / 63 * 0.85 + 0.04)) } } }
        effects.lut = try await lut(rows, dimension: 64, intensity: 0.75, colorSpace: .linearSRGB)
        var bypass = effects; bypass.isBypassed = true
        var measurements: [Measurement] = []
        for (name, value, duration) in [("bypassed-baseline", bypass, max(10, seconds / 2)), ("key-mask-framing-picture-linear-lut", effects, seconds)] {
            let renderer = SceneRenderer(imageProvider: { _ in background })
            try require(renderer.kernelMetrics.backend.contains("Metal"), "Sustained renderer lacks actual Metal device")
            for index in 0..<60 {
                try autoreleasepool {
                    _ = try render(renderer, source: frames[index % frames.count], effects: value, background: background,
                                   videoBackground: frames[(index + 12) % frames.count], sequence: Int64(index), size: bounds.size)
                }
            }
            let count = Int(duration * 30), start = DispatchTime.now().uptimeNanoseconds
            var wallTimes: [Double] = [], cadenceMisses = 0
            for index in 0..<count {
                let tick = DispatchTime.now().uptimeNanoseconds
                try autoreleasepool {
                    let frame = try render(renderer, source: frames[index % frames.count], effects: value, background: background,
                                           videoBackground: frames[(index + 12) % frames.count], sequence: Int64(index), size: bounds.size)
                    try require(frame.sequence == index && frame.presentationTime == CMTime(value: Int64(index), timescale: 30), "Sustained output lost frame identity/clock")
                    guard let buffer = frame.pixelBuffer else { throw NSError(domain: "ColorGPUQualification", code: 6) }
                    // Force destination availability rather than timing only
                    // construction of Core Image's lazy graph.
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let last = CVPixelBufferGetBytesPerRow(buffer) * (CVPixelBufferGetHeight(buffer)-1) + 3
                    let alpha = base[3]; let tailAlpha = base[last]
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    try require(alpha == 255 && tailAlpha == 255, "Sustained final background lost opaque canvas alpha")
                }
                let end = DispatchTime.now().uptimeNanoseconds
                wallTimes.append(Double(end - tick) / 1_000_000)
                let due = start + UInt64(Double(index + 1) * 1_000_000_000 / 30)
                if end > due + 33_333_333 { cadenceMisses += 1 }
                else if end < due { try await Task.sleep(for: .nanoseconds(Int64(due - end))) }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            wallTimes.sort()
            let p95 = wallTimes[min(wallTimes.count-1, Int(Double(wallTimes.count)*0.95))]
            let p99 = wallTimes[min(wallTimes.count-1, Int(Double(wallTimes.count)*0.99))]
            let misses = wallTimes.filter { $0 > 1000.0/30 }.count
            let qualifies = p95 <= 1000.0/30 && renderer.kernelMetrics.samples > 0 && cadenceMisses == 0
            let measurement = Measurement(name: name, frames: count, elapsedSeconds: elapsed, canvasWidth: 1920, canvasHeight: 1080, framesPerSecond: 30,
                renderMeanMilliseconds: wallTimes.reduce(0,+)/Double(wallTimes.count), render95thMilliseconds: p95, render99thMilliseconds: p99,
                renderMaximumMilliseconds: wallTimes.last ?? 0, renderBudgetMisses: misses, cadenceMisses: cadenceMisses,
                kernel: renderer.kernelMetrics, qualifies1080p30OnThisRun: qualifies)
            measurements.append(measurement)
            print("SUSTAINED \(name):\(count)frames/\(elapsed)s; CPU+completion mean\(measurement.renderMeanMilliseconds)ms,p95\(p95)ms,p99\(p99)ms,max\(measurement.renderMaximumMilliseconds)ms; budgetmisses\(misses),cadencemisses\(cadenceMisses); actual kernel samples\(renderer.kernelMetrics.samples),mean\(renderer.kernelMetrics.meanMilliseconds ?? -1)ms; qualifiedthisrun=\(qualifies)")
        }
        struct Report: Codable { let device: String; let hardwareSourceQualified: Bool; let measurements: [Measurement] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(device: device.name, hardwareSourceQualified: false, measurements: measurements)).write(to: directory.appendingPathComponent("sustained-metal-measurements.json"))
    }
}
