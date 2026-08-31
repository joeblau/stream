import AVFoundation
import CoreImage
import SwiftUI
import StreamCore

/// A zero-copy preview of the same AVCaptureSession feeding the broadcast
/// compositor. Dragging moves freely under the finger, then snaps to the nearest
/// supported compositor corner on release.
struct DraggableFacecamView: View {
    let frames: LatestCameraFrame
    let cameraPosition: CameraPosition
    let scale: Double
    @Binding var corner: PIPCorner
    let onFirstFrame: () -> Void

    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let previewSize = previewSize(in: geometry.size)
            let restingCenter = center(for: corner,
                                       previewSize: previewSize,
                                       geometry: geometry)

            FacecamPreviewSurface(frames: frames,
                                  cameraPosition: cameraPosition,
                                  onFirstFrame: onFirstFrame)
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
                .contentShape(.rect)
                .position(x: restingCenter.x + dragTranslation.width,
                          y: restingCenter.y + dragTranslation.height)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            let finalCenter = CGPoint(
                                x: restingCenter.x + value.translation.width,
                                y: restingCenter.y + value.translation.height
                            )
                            corner = nearestCorner(to: finalCenter, in: geometry.size)
                        }
                )
                .animation(.spring(duration: 0.3, bounce: 0.2), value: corner)
                .accessibilityLabel("Facecam preview")
                .accessibilityHint("Drag to move the facecam to another corner")
        }
    }

    private func previewSize(in container: CGSize) -> CGSize {
        let availableWidth = max(1, container.width - 32)
        let width = min(availableWidth,
                        container.width * max(0.10, min(0.40, CGFloat(scale))))
        // AVCaptureVideoDataOutput is rotated upright before compositing, so a
        // portrait screen receives a 3:4 preview and landscape receives 4:3.
        let height = width * (container.height >= container.width ? 4 / 3 : 3 / 4)
        return CGSize(width: width, height: height)
    }

    private func center(for corner: PIPCorner,
                        previewSize: CGSize,
                        geometry: GeometryProxy) -> CGPoint {
        let margin: CGFloat = 16
        let left = geometry.safeAreaInsets.leading + margin + previewSize.width / 2
        let right = geometry.size.width - geometry.safeAreaInsets.trailing
            - margin - previewSize.width / 2
        let top = geometry.safeAreaInsets.top + margin + previewSize.height / 2
        let bottom = geometry.size.height - geometry.safeAreaInsets.bottom
            - margin - previewSize.height / 2

        switch corner {
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }

    private func nearestCorner(to point: CGPoint, in container: CGSize) -> PIPCorner {
        let isLeft = point.x < container.width / 2
        let isTop = point.y < container.height / 2
        switch (isLeft, isTop) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}

private struct FacecamPreviewSurface: UIViewRepresentable {
    let frames: LatestCameraFrame
    let cameraPosition: CameraPosition
    let onFirstFrame: () -> Void

    func makeUIView(context: Context) -> FacecamPreviewUIView {
        let view = FacecamPreviewUIView()
        view.attach(to: frames,
                    cameraPosition: cameraPosition,
                    onFirstFrame: onFirstFrame)
        return view
    }

    func updateUIView(_ view: FacecamPreviewUIView, context: Context) {
        view.attach(to: frames,
                    cameraPosition: cameraPosition,
                    onFirstFrame: onFirstFrame)
    }
}

/// Software-backed preview. AVCaptureVideoPreviewLayer can be omitted or captured
/// inconsistently by ScreenCaptureKit; publishing CGImages into this ordinary layer
/// makes the foreground PiP reliably part of full-display capture.
private final class FacecamPreviewUIView: UIView {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private weak var frames: LatestCameraFrame?
    private var cameraPosition: CameraPosition = .front
    private var onFirstFrame: (() -> Void)?
    private var hasRenderedFrame = false
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(to frames: LatestCameraFrame,
                cameraPosition: CameraPosition,
                onFirstFrame: @escaping () -> Void) {
        if self.frames !== frames {
            self.frames = frames
            hasRenderedFrame = false
            layer.contents = nil
        }
        self.cameraPosition = cameraPosition
        self.onFirstFrame = onFirstFrame
        startDisplayLinkIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            // The camera is prewarmed while the sharing picker is onscreen, so its
            // latest frame is usually ready before this view exists. Draw it now
            // rather than waiting for the first display-link callback.
            renderLatestFrame()
            startDisplayLinkIfNeeded()
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard window != nil, displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderLatestFrame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15,
                                                        maximum: 30,
                                                        preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func renderLatestFrame() {
        guard let buffer = frames?.freshest() else {
            layer.contents = nil
            return
        }
        let orientation: CGImagePropertyOrientation =
            cameraPosition == .front ? .upMirrored : .up
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        layer.contents = cgImage
        if !hasRenderedFrame {
            hasRenderedFrame = true
            onFirstFrame?()
        }
    }
}
