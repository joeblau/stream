import AVFoundation
import CoreMedia
import Foundation

enum InterviewRecordedAnalysis {
    struct DecodedFile {
        let duration, videoEnd, audioEnd, flash, tone: Double
        let videoFrames, audioFrames, redFrames: Int
        let endsBlack: Bool
        let finalAudioPeak: Float
        let audioStart, toneTime: CMTime
        let audioValues: [Float]
    }
    static func decode(_ url: URL) async throws -> DecodedFile {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.count == 1 && audios.count == 1)
        let duration = try await asset.load(.duration).seconds
        let videoRange = try await videos[0].load(.timeRange), audioRange = try await audios[0].load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let picture = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let sound = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(picture); reader.add(sound); precondition(reader.startReading())
        var flash: Double?, tone: Double?, videoFrames = 0, audioFrames = 0, redFrames = 0
        var endsBlack = false, finalAudioPeak: Float = 0
        var audioStart: CMTime?, toneTime: CMTime?, audioValues: [Float] = []
        while let sample = picture.copyNextSampleBuffer() {
            videoFrames += 1
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("Decoded image missing") }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let offset = CVPixelBufferGetBytesPerRow(pixels) * (CVPixelBufferGetHeight(pixels) / 2)
                + (CVPixelBufferGetWidth(pixels) / 2) * 4
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            if flash == nil && bytes[offset] > 200 && bytes[offset + 1] > 200 && bytes[offset + 2] > 200 {
                flash = sample.presentationTimeStamp.seconds
            }
            if bytes[offset + 2] > 200 && bytes[offset] < 30 && bytes[offset + 1] < 30 { redFrames += 1 }
            endsBlack = bytes[offset] < 5 && bytes[offset + 1] < 5 && bytes[offset + 2] < 5
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        while let sample = sound.copyNextSampleBuffer() {
            if audioStart == nil { audioStart = sample.presentationTimeStamp }
            precondition(CMTimeCompare(sample.presentationTimeStamp,
                audioStart! + CMTime(value: Int64(audioFrames), timescale: 48_000)) == 0,
                "Decoded audio must occupy one contiguous rational sample grid")
            audioFrames += CMSampleBufferGetNumSamples(sample)
            let values = InterviewRecordingProbe.values(sample)
            precondition(audioValues.count + values.count <= 960_000, "Bounded ten-second stereo analysis")
            audioValues += values
            let decoded = InterviewRecordingProbe.pcm(sample)
            if tone == nil { tone = decoded.cue?.seconds; toneTime = decoded.cue }
            finalAudioPeak = decoded.peak
        }
        precondition(reader.status == .completed, reader.error?.localizedDescription ?? "AssetReader failed")
        precondition(flash != nil && tone != nil, "Actual compressed flash/tone must survive the complete receive/mix/render/write path")
        return .init(duration: duration, videoEnd: CMTimeRangeGetEnd(videoRange).seconds,
                     audioEnd: CMTimeRangeGetEnd(audioRange).seconds, flash: flash!, tone: tone!, videoFrames: videoFrames,
                     audioFrames: audioFrames, redFrames: redFrames, endsBlack: endsBlack, finalAudioPeak: finalAudioPeak,
                     audioStart: audioStart!, toneTime: toneTime!, audioValues: audioValues)
    }
    static func inspect(_ programURL: URL, isoURL: URL) async throws -> [String: Any] {
        let program = try await decode(programURL), iso = try await decode(isoURL)
        for file in [program, iso] {
            precondition(file.videoFrames > 50 && file.audioFrames > 96_000, "Enough actual compressed media must be decoded")
            precondition(file.redFrames > 20 && file.endsBlack && file.finalAudioPeak < 0.0001, "Decoded files must contain camera and end black and silent")
            precondition(abs(file.flash - file.tone) < 0.05, "Decoded file flash and tone must retain original AV timing")
            precondition(abs(file.videoEnd - file.audioEnd) < 0.04, "Decoded file audio and video endpoints must match")
        }
        precondition(abs(program.duration - iso.duration) < 0.04 && abs(program.flash - iso.flash) < 0.04, "Both files must share duration and flash timing")
        precondition(CMTimeCompare(program.audioStart, iso.audioStart) == 0 && program.audioFrames == iso.audioFrames, "Both files must retain exact audio origin and count")
        let cueDifference = CMTimeAbsoluteValue(program.toneTime - iso.toneTime)
        precondition(CMTimeCompare(cueDifference, CMTime(value: 1, timescale: 48_000)) <= 0, "Decoded AAC cue must stay within one rational sample")
        precondition(zip(program.audioValues, iso.audioValues).allSatisfy { $0.bitPattern == $1.bitPattern },
                     "Every real decoded Program/ISO Float32 sample must match exact bits")
        return ["decodedPCMFrames": program.audioFrames, "matchingFloat32Values": program.audioValues.count,
                "videoFrames": program.videoFrames, "isoVideoFrames": iso.videoFrames,
                "duration": program.duration, "programAVDelta": program.flash - program.tone,
                "isoAVDelta": iso.flash - iso.tone, "programEndDelta": program.videoEnd - program.audioEnd,
                "isoEndDelta": iso.videoEnd - iso.audioEnd, "rationalCueValue": cueDifference.value,
                "rationalCueScale": cueDifference.timescale, "endsBlackSilent": true]
    }
}
