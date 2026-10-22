import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

enum RecordingVideoSourceFactory {
    static func make(source: SourceDefinition, key: CaptureSourceKey, frames: SourceFrameProviders,
                     deliveryProvider: @escaping @Sendable () -> RecordingVideoFrameDelivery? = { nil }) -> IsolatedVideoSource {
        return IsolatedVideoSource {
            let renderer = Renderer(source: source, key: key, frames: frames, delivery: deliveryProvider())
            return IsolatedVideoSource.Render { size, pts, duration, sequence, processing, sourceTime in
                renderer.render(size: size, pts: pts, duration: duration, sequence: sequence, processing: processing, sourceTime: sourceTime)
            }
        }
    }
    /// An ISO subscription pins the admitted peer generation. Rejoining the
    /// same persistent slot cannot silently replace media in an existing file.
    static func makeGuest(source: SourceDefinition, lease: GuestReceiveLease,
                          frames: GuestVideoFrameStore,
                          deliveryProvider: @escaping @Sendable () -> RecordingVideoFrameDelivery? = { nil }) -> IsolatedVideoSource? {
        guard case .guest(let payload) = source.payload, payload.slotID == lease.slot else { return nil }
        return IsolatedVideoSource {
            let renderer = GuestRenderer(source: source, payload: payload, lease: lease, frames: frames, delivery: deliveryProvider())
            return IsolatedVideoSource.Render { size, pts, duration, sequence, processing, sourceTime in
                renderer.render(size: size, pts: pts, duration: duration, sequence: sequence, processing: processing, sourceTime: sourceTime)
            }
        }
    }

    private final class GuestRenderer: @unchecked Sendable {
        let source: SourceDefinition
        let payload: GuestSourcePayload
        let lease: GuestReceiveLease
        let frames: GuestVideoFrameStore
        var renderer: SceneRenderer?
        let delivery: RecordingIsolatedFrameDelivery
        init(source: SourceDefinition, payload: GuestSourcePayload, lease: GuestReceiveLease,
             frames: GuestVideoFrameStore, delivery: RecordingVideoFrameDelivery?) {
            self.source = source; self.payload = payload; self.lease = lease; self.frames = frames
            self.delivery = RecordingIsolatedFrameDelivery(delivery)
        }
        func render(size: CGSize, pts: CMTime, duration: CMTime, sequence: Int64,
                    processing: IsolatedVideoProcessing, sourceTime: CMTime) -> IsolatedVideoRenderedFrame? {
            let pixels = frames.pixels(slot: lease.slot, role: payload.role == .camera ? .camera : .screen,
                                       at: sourceTime, program: true, requiring: lease)
            let snapshot = Snapshot(camera: nil, pixels: pixels)
            let lookup = SourceFrameLookup(camera: { _ in nil }, screen: { _ in snapshot.pixels },
                                           guest: { _, _ in snapshot.pixels })
            let placement: LayerPayload = processing == .raw ? .screen(ScreenSourcePayload()) : source.payload
            let layer = LayerNode(name: source.name, sourceID: source.id, payload: placement, transform: .fullscreen,
                                  effectOverrides: processing == .raw ? .identity : nil)
            // Offline guest graphics belong to the scene, not to the source
            // tap. A retired/missing full lease records a marked black gap
            // even when the operator configured a Program placeholder.
            let scene = Scene(name: source.name, layers: pixels == nil ? [] : [layer], background: .solid(colorHex: "#000000"))
            let resources: RecordingVideoFrameDelivery
            do { resources = try delivery.resources(size: size) }
            catch { return .init(sample: nil, sourceAvailable: snapshot.pixels != nil,
                                 transferFailure: .admission(error.localizedDescription)) }
            if renderer == nil { renderer = SceneRenderer(frameAllocator: resources.sourceBank) }
            let frame = renderer?.render(scene: scene, overlayContext: .empty, canvasSize: size,
                                         frames: lookup, sourcePayloads: [source.id: placement], scenes: [:],
                                         presentationTime: pts, frameDuration: duration, sequence: sequence)
            return RecordingVideoSourceFactory.transferred(frame?.sampleBuffer, resources: resources, available: pixels != nil)
        }
    }

    private static func transferred(_ sample: CMSampleBuffer?, resources: RecordingVideoFrameDelivery,
                                    available: Bool) -> IsolatedVideoRenderedFrame {
        guard let sample else { return .init(sample: nil, sourceAvailable: available) }
        do {
            let copied = try FrameDeliveryConverter.copy(source: sample, into: resources.privateBank)
            return .init(sample: copied, sourceAvailable: available,
                         preparedVideo: .init(sample: copied, bank: resources.privateBank))
        } catch { return .init(sample: nil, sourceAvailable: available, transferFailure: .init(error)) }
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
        let delivery: RecordingIsolatedFrameDelivery
        private var cameraHolder: LatestCameraFrame?
        private var screenHolder: LatestScreenFrame?
        private var historyLease: RecordingSourceHistoryLease?
        init(source: SourceDefinition, key: CaptureSourceKey, frames: SourceFrameProviders, delivery: RecordingVideoFrameDelivery?) {
            self.source = source; self.key = key; self.frames = frames
            self.delivery = RecordingIsolatedFrameDelivery(delivery)
            refreshHistoryLease()
        }
        func render(size: CGSize, pts: CMTime, duration: CMTime, sequence: Int64,
                    processing: IsolatedVideoProcessing, sourceTime: CMTime) -> IsolatedVideoRenderedFrame? {
            refreshHistoryLease()
            let snapshot: Snapshot
            switch key {
            case .camera:
                let camera = cameraHolder?.recordingFrame(at: sourceTime)
                snapshot = Snapshot(camera: camera, pixels: camera?.buffer)
            case .screen:
                snapshot = Snapshot(camera: nil, pixels: screenHolder?.recordingFrame(at: sourceTime)?.buffer)
            default: return nil
            }
            let lookup = SourceFrameLookup(camera: { _ in snapshot.camera }, screen: { _ in snapshot.pixels })
            // Raw camera pixels use the unmirrored screen placement path;
            // processed cameras match the app's camera orientation/effects.
            let payload: LayerPayload = processing == .raw ? .screen(ScreenSourcePayload()) : source.payload
            let layer = LayerNode(name: source.name, sourceID: source.id, payload: payload, transform: .fullscreen,
                effectOverrides: processing == .raw ? .identity : nil)
            let scene = Scene(name: source.name, layers: [layer], background: .solid(colorHex: "#000000"))
            let resources: RecordingVideoFrameDelivery
            do { resources = try delivery.resources(size: size) }
            catch { return .init(sample: nil, sourceAvailable: snapshot.pixels != nil,
                                 transferFailure: .admission(error.localizedDescription)) }
            if renderer == nil { renderer = SceneRenderer(frameAllocator: resources.sourceBank) }
            let frame = renderer?.render(scene: scene, overlayContext: .empty, canvasSize: size,
                frames: lookup, sourcePayloads: [source.id: payload], scenes: [:],
                presentationTime: pts, frameDuration: duration, sequence: sequence)
            return RecordingVideoSourceFactory.transferred(frame?.sampleBuffer, resources: resources, available: snapshot.pixels != nil)
        }
        private func refreshHistoryLease() {
            switch key {
            case .camera:
                let holder = frames.recordingCameraHolder(for: key)
                if holder !== cameraHolder {
                    historyLease = nil; cameraHolder = holder
                    historyLease = holder?.acquireRecordingHistory()
                }
            case .screen:
                let holder = frames.recordingScreenHolder(for: key)
                if holder !== screenHolder {
                    historyLease = nil; screenHolder = holder
                    historyLease = holder?.acquireRecordingHistory()
                }
            default: break
            }
        }
    }
}
