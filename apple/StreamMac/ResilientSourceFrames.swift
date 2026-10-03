import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import StreamCore
import os.lock

/// Program-only frame wrapper. Preview keeps showing the real source state.
/// One retained buffer per demanded source bounds freeze memory; configuration
/// replaces the failed set atomically and never awaits a publisher.
final class ResilientSourceFrames: @unchecked Sendable {
    private struct Frame: @unchecked Sendable { var buffer: CVPixelBuffer; var position: CameraPosition = .back }
    private let cache = SourceFailoverCache<CaptureSourceKey, Frame>()
    private let raw: SourceFrameLookup
    private let offline: CVPixelBuffer?
    private var lock = os_unfair_lock_s()
    private var standbys: [CaptureSourceKey: CaptureSourceKey] = [:]
    init(raw: SourceFrameLookup) {
        self.raw = raw
        offline = Self.makeOfflineCard()
    }
    func configure(active: Set<CaptureSourceKey>, modes: [CaptureSourceKey: SourceFailureMode],
                   failed: Set<CaptureSourceKey>, standbys: [CaptureSourceKey: CaptureSourceKey]) {
        os_unfair_lock_lock(&lock); self.standbys = standbys; os_unfair_lock_unlock(&lock)
        cache.configure(active: active, modes: modes, failed: failed)
    }
    func clear() { cache.clear() }
    var lookup: SourceFrameLookup {
        SourceFrameLookup(camera: { [self] key in
            frame(key).map { LatestCameraFrame.Frame(buffer: $0.buffer, position: $0.position) }
        }, screen: { [self] key in frame(key)?.buffer }, media: { [self] key in frame(key)?.buffer },
            guest: raw.guest)
    }
    private func rawFrame(_ key: CaptureSourceKey) -> Frame? {
        switch key {
        case .camera:
            return raw.camera(key).map { Frame(buffer: $0.buffer, position: $0.position) }
        case .screen, .syphon, .web:
            return raw.screen(key).map { Frame(buffer: $0) }
        case .media, .pdf:
            return raw.media?(key).map { Frame(buffer: $0) }
        case .appAudio: return nil
        }
    }
    private func frame(_ key: CaptureSourceKey) -> Frame? {
        os_unfair_lock_lock(&lock); let standby = standbys[key]; os_unfair_lock_unlock(&lock)
        return cache.frame(for: key, live: { rawFrame(key) }, standby: { standby.flatMap(rawFrame) },
                           offline: { offline.map { Frame(buffer: $0) } })
    }
    private static func makeOfflineCard() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let text = NSAttributedString(string: "SOURCE OFFLINE", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 32, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.8, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (640 - width) / 2, y: 172)
        CTLineDraw(line, context)
        return buffer
    }
}
