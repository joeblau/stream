import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Optional decoder research only: no libvpx dependency in the shipping app.
@main struct G10DecoderHarness {
    struct NativeResult: Codable {
        var fixture: String
        var readable: Bool?
        var frames = 0
        var minimumAlpha: UInt8?
        var maximumAlpha: UInt8?
        var status: Int?
        var error: String?
    }

    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("libvpx: \(String(cString: g10_version()))")
        var nativeResults: [NativeResult] = []
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            nativeResults.append(await nativeProbe(url))
            guard url.pathExtension == "webm" else { continue }
            let container = try WebMContainerParser.parse(Data(contentsOf: url))
            guard let track = container.videoTrack else { continue }
            guard track.codecID == "V_VP8" || track.codecID == "V_VP9" else {
                print("OPTIONAL \(url.lastPathComponent): unsupported \(track.codecID)")
                continue
            }
            let frames = container.frames(forTrack: track.number)
            guard !frames.isEmpty else { throw CocoaError(.coderInvalidValue) }
            let width = Int(track.pixelWidth), height = Int(track.pixelHeight)
            guard width > 0, height > 0, width <= 4096, height <= 4096,
                  let decoder = g10_create(track.codecID == "V_VP9" ? 1 : 0, UInt32(width), UInt32(height))
            else { throw CocoaError(.coderInvalidValue) }
            defer { g10_destroy(decoder) }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            var hashes: [UInt64] = [], timestamps: [Int64] = []
            var alphaMin: UInt8 = 255, alphaMax: UInt8 = 0
            let started = ContinuousClock.now
            for (index, frame) in frames.enumerated() {
                try decode(frame, container: container, decoder: decoder, rgba: &rgba)
                hashes.append(hash(rgba))
                timestamps.append(frame.timestampNs)
                for pixel in stride(from: 3, to: rgba.count, by: 4) {
                    alphaMin = min(alphaMin, rgba[pixel]); alphaMax = max(alphaMax, rgba[pixel])
                }
                if index == 30 {
                    try save(rgba, width: width, height: height,
                             to: output.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png"))
                    try Data(stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
                        .write(to: output.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".alpha"))
                }
            }
            // Fresh decoder seeks to the latest preceding keyframe and prerolls.
            let target = min(frames.count - 1, frames.count / 2 + 7)
            let anchor = frames[...target].lastIndex(where: { $0.isKeyframe }) ?? 0
            guard let seekDecoder = g10_create(track.codecID == "V_VP9" ? 1 : 0, UInt32(width), UInt32(height))
            else { throw CocoaError(.coderInvalidValue) }
            defer { g10_destroy(seekDecoder) }
            for frame in frames[anchor...target] { try decode(frame, container: container, decoder: seekDecoder, rgba: &rgba) }
            precondition(hash(rgba) == hashes[target], "Seek must reproduce the sequentially decoded frame")
            precondition(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 <= $1 })
            if track.hasAlphaMode { precondition(alphaMin < alphaMax && alphaMin < 255) }
            print("OPTIONAL \(url.lastPathComponent): \(frames.count) frames, \(width)x\(height), alpha \(alphaMin)...\(alphaMax), PTS \(timestamps.first ?? 0)...\(timestamps.last ?? 0) ns, seek \(target) via keyframe \(anchor) MATCH; RGBA buffer \(rgba.count) bytes")
            print("DECODE+SEEK \(url.lastPathComponent): \(started.duration(to: .now))")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(nativeResults).write(to: output.appendingPathComponent("native-probes.json"))
        if CommandLine.arguments.contains("--require-native-controls") {
            for name in ["h264-opaque.mp4", "prores4444-alpha.mov"] {
                guard let result = nativeResults.first(where: { $0.fixture == name }),
                      result.status == AVAssetReader.Status.completed.rawValue,
                      result.frames == 60, result.error == nil else {
                    throw NSError(domain: "G10.NativeControl", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Native control did not decode all 60 frames: \(name)"])
                }
                if name == "prores4444-alpha.mov" {
                    guard result.minimumAlpha == 0, result.maximumAlpha == 255 else {
                        throw NSError(domain: "G10.NativeAlpha", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Native ProRes control lost alpha"])
                    }
                }
            }
            print("PASS: native H.264 and ProRes alpha controls decoded all 60 frames")
        }
    }

    static func decode(_ frame: WebMFrame, container: WebMContainer,
                       decoder: OpaquePointer, rgba: inout [UInt8]) throws {
        let color = container.source.subdata(in: frame.payload)
        let alpha = frame.alphaPayload.map { container.source.subdata(in: $0) } ?? Data()
        let result = color.withUnsafeBytes { c in alpha.withUnsafeBytes { a in
            rgba.withUnsafeMutableBufferPointer { out in
                g10_decode(decoder, c.bindMemory(to: UInt8.self).baseAddress, color.count,
                           a.bindMemory(to: UInt8.self).baseAddress, alpha.count,
                           out.baseAddress, out.count)
            }
        } }
        guard result == 1 else { throw NSError(domain: "G10.Decode", code: Int(result)) }
    }

    static func hash(_ rgba: [UInt8]) -> UInt64 {
        rgba.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    static func save(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func nativeProbe(_ url: URL) async -> NativeResult {
        var result = NativeResult(fixture: url.lastPathComponent)
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let readable = try await asset.load(.isReadable)
            result.readable = readable
            guard let track = tracks.first else {
                print("NATIVE \(url.lastPathComponent): readable=\(readable), no video track")
                return result
            }
            print("NATIVE \(url.lastPathComponent): container readable=\(readable), video track recognized")
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings:
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.coderInvalidValue) }
            var count = 0, minimum: UInt8 = 255, maximum: UInt8 = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
                count += 1
                CVPixelBufferLockBaseAddress(image, .readOnly)
                if let address = CVPixelBufferGetBaseAddress(image) {
                    let bytes = address.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<CVPixelBufferGetHeight(image) {
                        for x in 0..<CVPixelBufferGetWidth(image) {
                            let a = bytes[y * CVPixelBufferGetBytesPerRow(image) + x * 4 + 3]
                            minimum = min(minimum, a); maximum = max(maximum, a)
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
            print("NATIVE \(url.lastPathComponent): readable=\(readable), frames=\(count), alpha \(minimum)...\(maximum), status=\(reader.status.rawValue), error=\(String(describing: reader.error))")
            result.frames = count
            result.minimumAlpha = count > 0 ? minimum : nil
            result.maximumAlpha = count > 0 ? maximum : nil
            result.status = reader.status.rawValue
            result.error = reader.error.map { String(describing: $0) }
        } catch {
            result.error = String(describing: error)
            print("NATIVE \(url.lastPathComponent): \(error)")
        }
        return result
    }
}
