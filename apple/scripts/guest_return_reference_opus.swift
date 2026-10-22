#if STREAM_GUEST_RFC_OPUS_VALIDATION
import CoreMedia
import CryptoKit
import Darwin
import Foundation

/// Validation-only cross-implementation decoder. Consumes exact owned payload
/// bytes from the shipping encoder; never encodes, captures or opens a device.
enum OwnedReferenceOpus {
    typealias Create = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    typealias Decode = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int32, UnsafeMutablePointer<Float>?, Int32, Int32) -> Int32
    typealias Frames = @convention(c) (UnsafePointer<UInt8>?, Int32, Int32) -> Int32
    typealias Channels = @convention(c) (UnsafePointer<UInt8>?) -> Int32
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?

    static func decode(_ packets: [(Data, CMTime, UInt32)]) -> [String: Any] {
        guard let supplied = ProcessInfo.processInfo.environment["STREAM_GUEST_RFC_OPUS_LIBRARY"], supplied.hasPrefix("/") else {
            return ["unavailable": "explicit-existing-library-required"]
        }
        let url = URL(fileURLWithPath: supplied).resolvingSymlinksInPath()
        guard let libraryBytes = try? Data(contentsOf: url), let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            return ["unavailable": "library-open"]
        }
        defer { dlclose(library) }
        guard let c = dlsym(library, "opus_decoder_create"), let d = dlsym(library, "opus_decoder_destroy"),
              let f = dlsym(library, "opus_decode_float"), let n = dlsym(library, "opus_packet_get_nb_samples"),
              let ch = dlsym(library, "opus_packet_get_nb_channels"), let v = dlsym(library, "opus_get_version_string") else {
            return ["unavailable": "reference-symbols"]
        }
        let create = unsafeBitCast(c, to: Create.self), destroy = unsafeBitCast(d, to: Destroy.self)
        let decode = unsafeBitCast(f, to: Decode.self), frames = unsafeBitCast(n, to: Frames.self)
        let channels = unsafeBitCast(ch, to: Channels.self), version = unsafeBitCast(v, to: Version.self)
        var error: Int32 = 0
        guard let decoder = create(48_000, 2, &error), error == 0 else { return ["unavailable": "reference-create", "error": error] }
        defer { destroy(decoder) }
        var decodedFrames = 0, square = [0.0, 0.0], real = Array(repeating: [Double](repeating: 0, count: 4), count: 2), imaginary = real
        let frequencies = [1000.0, 1700.0, 440.0, 880.0]
        var digest = SHA256(), steps: [UInt32] = [], ptsSteps: [Int64] = []
        for (index, packet) in packets.enumerated() {
            let (data, pts, rtp) = packet
            guard pts.isNumeric, !data.isEmpty, data.count <= 1_275 else { return ["unavailable": "source-packet-boundary"] }
            digest.update(data: data)
            if index > 0 {
                steps.append(rtp &- packets[index - 1].2)
                let delta = CMTimeConvertScale(pts - packets[index - 1].1, timescale: 48_000, method: .roundHalfAwayFromZero).value
                ptsSteps.append(delta)
            }
            var pcm = [Float](repeating: 0, count: 960 * 2)
            let status: Int32 = data.withUnsafeBytes { raw in
                let pointer = raw.bindMemory(to: UInt8.self).baseAddress!
                guard frames(pointer, Int32(data.count), 48_000) == 960, channels(pointer) == 2 else { return -10_001 }
                return decode(decoder, pointer, Int32(data.count), &pcm, 960, 0)
            }
            guard status == 960, pcm.allSatisfy(\.isFinite) else { return ["unavailable": "reference-packet", "error": status, "index": index] }
            decodedFrames += 960
            for sample in 0..<960 { for side in 0..<2 { square[side] += Double(pcm[sample * 2 + side]) * Double(pcm[sample * 2 + side]) } }
            for (bin, hz) in frequencies.enumerated() {
                let phase = pts.seconds.truncatingRemainder(dividingBy: 1) * 2 * .pi * hz, step = 2 * .pi * hz / 48_000
                let cs = cos(step), sn = sin(step); var cosine = cos(phase), sine = sin(phase)
                for sample in 0..<960 {
                    for side in 0..<2 { let value = Double(pcm[sample * 2 + side]); real[side][bin] += value * cosine; imaginary[side][bin] += value * sine }
                    let next = cosine * cs - sine * sn; sine = sine * cs + cosine * sn; cosine = next
                }
            }
        }
        var malformed: UInt8 = 0xff
        let rejectedMalformed = frames(&malformed, 1, 48_000) < 0
        return ["implementation": version().map { String(cString: $0) } ?? "unknown", "libraryPath": url.path,
                "librarySHA256": SHA256.hash(data: libraryBytes).map { String(format: "%02x", $0) }.joined(),
                "payloadAggregateSHA256": digest.finalize().map { String(format: "%02x", $0) }.joined(),
                "packets": packets.count, "frames": decodedFrames, "rate": 48_000, "sourceRTPAll960": !steps.isEmpty && steps.allSatisfy { $0 == 960 },
                "sourcePTSAll960": !ptsSteps.isEmpty && ptsSteps.allSatisfy { $0 == 960 }, "packetFrames": 960, "packetChannels": 2,
                "malformedTOCRejected": rejectedMalformed,
                "firstSourcePTS": packets.first?.1.seconds ?? 0, "lastSourcePTS": packets.last?.1.seconds ?? 0,
                "channels": (0..<2).map { side in ["rms": decodedFrames > 0 ? sqrt(square[side] / Double(decodedFrames)) : 0,
                    "amplitudes1000_1700_440_880": (0..<4).map { bin in decodedFrames > 0 ? 2 * hypot(real[side][bin], imaginary[side][bin]) / Double(decodedFrames) : 0 }] as [String: Any] }]
    }
}
#endif
