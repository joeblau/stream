import CoreMedia
import CoreVideo
import Foundation

enum VirtualCameraContract {
    static let extensionID = "com.joeblau.StreamMac.CameraExtension"
    static let deviceID = UUID(uuidString: "A27D88D1-BF58-4C73-A822-083D4E422EC4")!
    static let streamID = UUID(uuidString: "5A7ED550-630F-484C-9F21-536342C90587")!
    static let width = 1920, height = 1080, fps = 30
    static let sinkStreamID = UUID(uuidString: "BE8A742D-0FA2-4105-9398-D699772BEB93")!
    static let staleNanoseconds: UInt64 = 500_000_000
    static var hostNanoseconds: UInt64 {
        let time = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .roundTowardZero)
        return UInt64(max(0, time.value))
    }
}

/// One newest validated frame. The CMIO sink is the cross-process transport;
/// this mailbox is local to the extension and never retains a frame history.
final class VirtualCameraMailbox: @unchecked Sendable {
    struct Frame: @unchecked Sendable { let pixelBuffer: CVPixelBuffer; let pts: UInt64; let sequence: UInt64; let arrived: UInt64 }
    private let lock = NSLock()
    private var frame: Frame?
    private var lastPTS: UInt64 = 0
    private var dropped: UInt64 = 0
    var droppedFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return dropped }
    @discardableResult
    func submit(_ buffer: CMSampleBuffer, sequence: UInt64, now: UInt64 = VirtualCameraContract.hostNanoseconds) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard let pixels = CMSampleBufferGetImageBuffer(buffer), CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixels) > 0, CVPixelBufferGetWidth(pixels) <= 1920,
              CVPixelBufferGetHeight(pixels) > 0, CVPixelBufferGetHeight(pixels) <= 1080,
              time.isValid, !time.isIndefinite, time.seconds.isFinite, time.seconds >= 0 else { dropped += 1; return false }
        let pts = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundTowardZero).value
        guard pts > 0, UInt64(pts) > lastPTS, UInt64(pts) <= now + 100_000_000,
              now <= UInt64(pts) || now - UInt64(pts) <= VirtualCameraContract.staleNanoseconds else { dropped += 1; return false }
        lastPTS = UInt64(pts)
        frame = Frame(pixelBuffer: pixels, pts: UInt64(pts), sequence: sequence, arrived: now)
        return true
    }
    func latest(now: UInt64 = VirtualCameraContract.hostNanoseconds) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let frame, frame.arrived <= now, now - frame.arrived <= VirtualCameraContract.staleNanoseconds else { return nil }
        return frame
    }
    func clear() { lock.lock(); frame = nil; lastPTS = 0; lock.unlock() }
}
