import AVFoundation
import CoreMedia
import Foundation

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "PerformanceEvidence", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct PerformanceEvidenceHarness {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = PerformanceEvidenceJournal(directory: directory)
        if CommandLine.arguments.contains("--failed-qualification") {
            // Reproduce the hosted capacity boundary without spending another
            // 1,200s. The original run did NOT report a decoded-frame count;
            // 11,722 below is deliberate fixture input, not recovered evidence.
            let first = PerformanceWorkloadCheck.cadence(fps: 30, seconds: 600, rendered: 11_722,
                decoded: 0, source: nil)
            try journal.write(first, name: "case-0.json")
            let source = PerformanceReplayInventory(availableFrames: 11_722,
                framesDueBeforeGraceEnd: 11_624, durationSeconds: 600, monotonic: true)
            let second = PerformanceWorkloadCheck.cadence(fps: 30, seconds: 600,
                rendered: 12_140, decoded: 11_722, source: source)
            try journal.write(second, name: "case-1.json")
            struct FailedReport: Codable { var status = "failed"; var workloads: [[PerformanceWorkloadCheck]] }
            try journal.write(FailedReport(workloads: [first, second]), name: "performance.json")
            exit(1)
        }

        // Actual H.264 source provides 20, not 30, frames in one second.
        let url = directory.appendingPathComponent("actual-20fps.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        try require(writer.startWriting(), "Writer start failed")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            let deadline = ContinuousClock.now + .seconds(5)
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try require(input.isReadyForMoreMediaData, "Writer readiness deadline")
            var pixels: CVPixelBuffer?
            try require(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess, "Pixel allocation failed")
            CVPixelBufferLockBaseAddress(pixels!, [])
            memset(CVPixelBufferGetBaseAddress(pixels!)!, Int32(frame * 10), CVPixelBufferGetDataSize(pixels!))
            CVPixelBufferUnlockBaseAddress(pixels!, [])
            try require(adaptor.append(pixels!, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)), "Writer append failed")
        }
        input.markAsFinished(); await writer.finishWriting()
        try require(writer.status == .completed, "Writer completion failed")
        let source = try await PerformanceOwnedReplay.inventory(url: url, workloadSeconds: 600)
        try require(source.availableFrames == 20 && source.framesDueBeforeGraceEnd == 20 && source.monotonic,
            "Compressed inventory must count the actual sparse source")
        let replay = PerformanceOwnedReplay()
        try await replay.run(url: url)
        try require(replay.decodedFrames == 20, "Real media-clock decoder lost actual input frames")
        let checks = PerformanceWorkloadCheck.cadence(fps: 30, seconds: 600,
            rendered: 12_140, decoded: replay.decodedFrames, source: source)
        try require(checks.first { $0.name == "actualSourceDecodeCadence" }?.status == .passed,
            "Actual sparse-source decoding must be distinguished from capacity")
        try require(checks.filter { $0.name.hasPrefix("nominal") }.allSatisfy { $0.status == .failed },
            "Sparse decode success cannot relax any nominal30fps qualification")
        let slow = PerformanceWorkloadCheck.cadence(fps: 30, seconds: 600, rendered: 18_000,
            decoded: 10, source: source)
        try require(slow.first { $0.name == "actualSourceDecodeCadence" }?.status == .failed,
            "A decoder missing available input cannot pass")
        let full = PerformanceWorkloadCheck.cadence(fps: 30, seconds: 600, rendered: 18_000, decoded: 18_000,
            source: .init(availableFrames: 18_000, framesDueBeforeGraceEnd: 17_850, durationSeconds: 600, monotonic: true))
        try require(full.allSatisfy { $0.status == .passed }, "Original sufficient30fps case should pass")
        try journal.write(checks, name: "actual-source-checks.json")
        print("PASS: actual20fps H264 inventory and media-clock decoding; separate unchanged30fps failure; missing-source-frame failure; original nominal threshold positive control")
    }
}
