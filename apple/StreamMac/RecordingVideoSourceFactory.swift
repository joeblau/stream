import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

enum RecordingVideoSourceFactory {
    static func make(source: SourceDefinition, key: CaptureSourceKey, frames: SourceFrameProviders) -> IsolatedVideoSource {
        return IsolatedVideoSource {
            let renderer = Renderer(source: source, key: key, frames: frames)
            return { size, pts, duration, sequence, processing in
                renderer.render(size: size, pts: pts, duration: duration, sequence: sequence, processing: processing)
            }
        }
    }
    private final class Snapshot: @unchecked Sendable {
        let camera: LatestCameraFrame.Frame?
        let pixels: CVPixelBuffer?
        init(camera: LatestCameraFrame.Frame?, pixels: CVPixelBuffer?) { self.camera = camera; self.pixels = pixels }
    }
    /// Created on the main actor; rendering and lazy renderer creation run
    /// only on one IsolatedVideoRecorder's serial worker.
    private final class Renderer: @unchecked Sendable {
        let source: SourceDefinition
        let key: CaptureSourceKey
        let frames: SourceFrameProviders
        var renderer: SceneRenderer?
        init(source: SourceDefinition, key: CaptureSourceKey, frames: SourceFrameProviders) {
            self.source = source; self.key = key; self.frames = frames
        }
        func render(size: CGSize, pts: CMTime, duration: CMTime, sequence: Int64,
                    processing: IsolatedVideoProcessing) -> IsolatedVideoRenderedFrame? {
            let camera: LatestCameraFrame.Frame?
            let pixels: CVPixelBuffer?
            switch key {
            case .camera: camera = frames.cameraFrame(for: key); pixels = camera?.buffer
            case .screen: camera = nil; pixels = frames.screenFrame(for: key)
            default: return nil
            }
            let snapshot = Snapshot(camera: camera, pixels: pixels)
            let lookup = SourceFrameLookup(camera: { _ in snapshot.camera }, screen: { _ in snapshot.pixels })
            // Raw camera pixels use the unmirrored screen placement path;
            // processed cameras match the app's camera orientation/effects.
            let payload: LayerPayload = processing == .raw ? .screen(ScreenSourcePayload()) : source.payload
            let layer = LayerNode(name: source.name, sourceID: source.id, payload: payload, transform: .fullscreen,
                effectOverrides: processing == .raw ? .identity : nil)
            let scene = Scene(name: source.name, layers: [layer], background: .solid(colorHex: "#000000"))
            if renderer == nil { renderer = SceneRenderer() }
            let frame = renderer?.render(scene: scene, overlayContext: .empty, canvasSize: size,
                frames: lookup, sourcePayloads: [source.id: payload], scenes: [:],
                presentationTime: pts, frameDuration: duration, sequence: sequence)
            return IsolatedVideoRenderedFrame(sample: frame?.sampleBuffer, sourceAvailable: pixels != nil)
        }
    }
}
