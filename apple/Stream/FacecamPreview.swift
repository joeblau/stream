import AVFoundation
import CoreImage
import Metal
import SwiftUI
import StreamCore

/// A zero-copy preview of the same AVCaptureSession feeding the broadcast
/// compositor. Dragging moves freely under the finger, then snaps to the nearest
/// supported compositor corner on release. A single tap reveals a camera-flip
/// button over the card; flipping spins the card on its vertical axis while the
/// session swaps cameras underneath.
struct DraggableFacecamView: View {
    let frames: LatestCameraFrame
    let cameraPosition: CameraPosition
    let scale: Double
    @Binding var corner: PIPCorner
    let onFirstFrame: () -> Void
    /// Asks the owner to switch the live capture session to the other camera.
    let onFlipCamera: () -> Void

    @GestureState private var dragTranslation = CGSize.zero
    /// Whether the flip control is currently revealed over the card.
    @State private var showsControls = false
    /// Regenerated on every reveal and every flip so the auto-hide `task` restarts
    /// instead of dismissing the controls a fixed interval after the first tap.
    @State private var controlsRevealID = UUID()
    /// Accumulated flip rotation. Each flip adds a half turn rather than toggling
    /// between two values, so repeated taps keep spinning the same direction
    /// instead of rocking back and forth.
    @State private var flipAngle: Double = 0
    /// True for the length of the turn. Throttles the preview and rejects a second
    /// flip, so rapidly tapping back and forth cannot queue up capture-session
    /// reconfigurations faster than the hardware retires them.
    @State private var isFlipping = false

    /// Preview refresh while the card sits still: the camera's own rate.
    private static let restingFrameRate = 30
    /// Preview refresh during the turn. The card is dimmed and moving, so the
    /// dropped frames are not visible — but the main thread gets them back to
    /// commit the animation.
    private static let flippingFrameRate = 10
    private static let flipDuration: TimeInterval = 0.5

    var body: some View {
        GeometryReader { geometry in
            let previewSize = previewSize(in: geometry.size)
            let restingCenter = center(for: corner,
                                       previewSize: previewSize,
                                       geometry: geometry)

            FacecamPreviewSurface(
                frames: frames,
                // The card is turning and dimmed, so a slower preview is invisible —
                // while the main-thread Core Image render this drops is the work most
                // likely to miss an animation frame.
                preferredFrameRate: isFlipping ? Self.flippingFrameRate : Self.restingFrameRate,
                onFirstFrame: onFirstFrame
            )
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 1)
                }
                .contentShape(.rect)
                .onTapGesture {
                    Haptics.tap()
                    controlsRevealID = UUID()
                    withAnimation(.spring(duration: 0.28, bounce: 0.25)) {
                        showsControls.toggle()
                    }
                }
                .overlay {
                    if showsControls { flipButton }
                }
                .modifier(CameraFlipEffect(angle: flipAngle))
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
                .accessibilityHint("Drag to move the facecam to another corner. Tap to show the camera flip button.")
        }
        // Auto-hide the controls a few seconds after the last interaction. Keyed on
        // the reveal id so a second tap restarts the countdown, and cancellation
        // (id change) skips the stale dismissal.
        .task(id: controlsRevealID) {
            guard showsControls else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showsControls = false }
        }
    }

    /// A plain scrim circle rather than a glass material. The button sits inside the
    /// card, so anything with a backdrop filter would have its blur re-sampled
    /// through the 3-D transform on every frame of the turn — by far the most
    /// expensive thing that could ride along with the rotation.
    private var flipButton: some View {
        Button(action: flip) {
            Image(systemName: "camera.rotate.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .accessibilityLabel(cameraPosition == .front
                            ? "Switch to back camera"
                            : "Switch to front camera")
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    /// Swaps the camera immediately and starts the half turn. The order matters:
    /// AVCaptureSession takes a couple of hundred milliseconds to deliver its first
    /// frame from the new device, so kicking it off at the top of a half-second
    /// animation lands the new feed around the edge-on frame, where the dim hides the
    /// changeover. Until then the card keeps showing the outgoing camera's last
    /// frame — correctly mirrored, because the mirroring follows the pixels.
    ///
    /// The turn also dismisses the control and throttles the preview: both take
    /// per-frame compositing work off the rotating subtree for its duration.
    private func flip() {
        guard !isFlipping else { return }
        Haptics.tap()
        isFlipping = true
        controlsRevealID = UUID()
        withAnimation(.easeOut(duration: 0.12)) { showsControls = false }
        onFlipCamera()
        // `.smooth` rather than a spring: a bouncing flip overshoots past the half
        // turn and settles back through it, which reads as a wobble on a card whose
        // content is changing at the same time.
        withAnimation(.smooth(duration: Self.flipDuration)) {
            flipAngle += 180
        } completion: {
            isFlipping = false
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

/// A coin flip around the card's vertical axis.
///
/// Conforming to `Animatable` is what makes this work: SwiftUI re-evaluates `body`
/// once per display frame with the interpolated angle, so both corrections track
/// the rotation continuously instead of snapping when the state changes.
///
/// - Past 90° the viewer is looking at the *back* of the card, where the video
///   would read reversed — counter-mirroring keeps it upright the whole way round.
/// - A dim peaking exactly at the edge-on frame covers the instant the card has no
///   thickness, which is also where the new camera's first frames arrive.
/// `ViewModifier` infers main-actor isolation while `Animatable` is nonisolated, so
/// under strict concurrency the conformance has to be marked `@preconcurrency`.
/// SwiftUI only ever drives `animatableData` from the main thread.
private struct CameraFlipEffect: ViewModifier, @preconcurrency Animatable {
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    /// 0 when the card faces the viewer, 1 when it is exactly edge-on.
    private var edgeOn: Double {
        abs(sin(angle * .pi / 180))
    }

    private var isShowingBack: Bool {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        let normalized = remainder < 0 ? remainder + 360 : remainder
        return normalized > 90 && normalized < 270
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(edgeOn * 0.7))
            }
            .scaleEffect(x: isShowingBack ? -1 : 1, y: 1)
            // The card's shadow, faded out as it turns edge-on. Keeping it inside the
            // rotation is both more correct (the shadow turns with the card) and much
            // cheaper: an unset `shadowPath` makes Core Animation rasterize the layer
            // offscreen to blur it, and it must redo that whenever the video contents
            // change. At zero opacity that pass is skipped altogether, so the fastest
            // part of the turn is also the cheapest part to composite.
            .shadow(color: .black.opacity(0.45 * (1 - edgeOn)), radius: 12, y: 5)
            .rotation3DEffect(.degrees(angle),
                              axis: (x: 0, y: 1, z: 0),
                              perspective: 0.35)
    }
}

private struct FacecamPreviewSurface: UIViewRepresentable {
    let frames: LatestCameraFrame
    let preferredFrameRate: Int
    let onFirstFrame: () -> Void

    func makeUIView(context: Context) -> FacecamPreviewUIView {
        let view = FacecamPreviewUIView()
        view.attach(to: frames,
                    preferredFrameRate: preferredFrameRate,
                    onFirstFrame: onFirstFrame)
        return view
    }

    func updateUIView(_ view: FacecamPreviewUIView, context: Context) {
        view.attach(to: frames,
                    preferredFrameRate: preferredFrameRate,
                    onFirstFrame: onFirstFrame)
    }
}

/// Draws the facecam into an ordinary app layer. AVCaptureVideoPreviewLayer can be
/// omitted or captured inconsistently by ScreenCaptureKit; rendering the frames
/// ourselves makes the foreground PiP reliably part of full-display capture.
///
/// This runs on the main thread for the whole broadcast, alongside ScreenCaptureKit
/// capture, facecam compositing, and the H.264 encoder, so the render path avoids:
///  - re-rendering a camera frame that is already on screen (the camera and the
///    display link free-run against each other, so many ticks see no new frame);
///  - a CPU round trip. Core Image renders straight into a `CAMetalLayer` drawable,
///    so the frame never leaves the GPU. Going through `createCGImage` instead meant
///    rendering on the GPU, reading the result back into a freshly allocated CPU
///    buffer, and having Core Animation upload it again — every frame, for the whole
///    broadcast;
///  - rendering more pixels than the layer shows: the aspect-fill lands the sensor
///    frame directly at the drawable's size, which for this thumbnail-sized card is a
///    fraction of the 640x480 the camera delivers.
private final class FacecamPreviewUIView: UIView {
    /// One device, one command queue, and a `CIContext` bound to that queue so Core
    /// Image encodes its work into the same command buffer that presents the frame.
    private struct MetalStack {
        let commandQueue: MTLCommandQueue
        let ciContext: CIContext

        var device: any MTLDevice { commandQueue.device }

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let commandQueue = device.makeCommandQueue() else { return nil }
            self.commandQueue = commandQueue
            self.ciContext = CIContext(mtlCommandQueue: commandQueue,
                                       options: [.cacheIntermediates: false])
        }
    }

    private static let metalStack = MetalStack()
    /// Used only where there is no Metal device at all (the Simulator). Software Core
    /// Image is slow, but nothing else in this pipeline runs there either.
    private static let fallbackContext = CIContext(options: [.cacheIntermediates: false])
    private static let displayColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Present when the device has a GPU. Added as a sublayer rather than via
    /// `layerClass` so the fallback path can keep using `layer.contents`.
    private let metalLayer: CAMetalLayer?

    private weak var frames: LatestCameraFrame?
    private var onFirstFrame: (() -> Void)?
    private var hasRenderedFrame = false
    private var displayLink: CADisplayLink?
    /// The buffer and camera behind the pixels currently on screen, so an unchanged
    /// frame costs a pointer comparison instead of a render.
    private var lastRenderedBuffer: CVPixelBuffer?
    private var lastRenderedPosition: CameraPosition?
    private var preferredFrameRate = 30

    override init(frame: CGRect) {
        if let stack = Self.metalStack {
            let metalLayer = CAMetalLayer()
            metalLayer.device = stack.device
            metalLayer.pixelFormat = .bgra8Unorm
            // Core Image writes into the drawable's texture, which needs more than
            // the default render-target-only usage.
            metalLayer.framebufferOnly = false
            metalLayer.isOpaque = true
            // Every drawable acquired here is presented immediately, so a small pool
            // is enough — and keeps `nextDrawable()` from ever having to wait.
            metalLayer.maximumDrawableCount = 3
            self.metalLayer = metalLayer
        } else {
            self.metalLayer = nil
        }
        super.init(frame: frame)
        backgroundColor = .black
        layer.masksToBounds = true
        if let metalLayer {
            metalLayer.contentsScale = layer.contentsScale
            // Nothing has been drawn yet; stay hidden so the black background shows
            // instead of an undefined drawable.
            metalLayer.isHidden = true
            layer.addSublayer(metalLayer)
        } else {
            layer.contentsGravity = .resizeAspectFill
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metalLayer else { return }
        // The card resizes with the overlay-size slider and animates as it moves
        // between corners; an implicit sublayer animation would lag the video behind
        // its own frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = layer.contentsScale
        let drawableSize = CGSize(
            width: max(1, (bounds.width * layer.contentsScale).rounded()),
            height: max(1, (bounds.height * layer.contentsScale).rounded())
        )
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
        CATransaction.commit()
    }

    func attach(to frames: LatestCameraFrame,
                preferredFrameRate: Int,
                onFirstFrame: @escaping () -> Void) {
        if self.frames !== frames {
            self.frames = frames
            clearContents()
        }
        self.onFirstFrame = onFirstFrame
        setPreferredFrameRate(preferredFrameRate)
        startDisplayLinkIfNeeded()
    }

    /// Retunes the running display link. Called when the card starts and finishes a
    /// flip, so the throttle costs two property writes rather than tearing the link
    /// down and building a new one.
    private func setPreferredFrameRate(_ fps: Int) {
        let clamped = max(1, min(fps, 30))
        guard clamped != preferredFrameRate else { return }
        preferredFrameRate = clamped
        displayLink?.preferredFrameRateRange = Self.frameRateRange(for: clamped)
    }

    private static func frameRateRange(for fps: Int) -> CAFrameRateRange {
        CAFrameRateRange(minimum: Float(max(1, fps / 2)),
                         maximum: Float(fps),
                         preferred: Float(fps))
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
        link.preferredFrameRateRange = Self.frameRateRange(for: preferredFrameRate)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func clearContents() {
        metalLayer?.isHidden = true
        layer.contents = nil
        lastRenderedBuffer = nil
        lastRenderedPosition = nil
        hasRenderedFrame = false
    }

    @objc private func renderLatestFrame() {
        guard let frame = frames?.freshest() else {
            // Only clear once. Reassigning contents every tick while the camera is
            // between sessions is 30 pointless layer updates a second.
            if lastRenderedBuffer != nil { clearContents() }
            return
        }
        // The camera runs at 30 fps and the display link free-runs beside it, so a
        // large share of ticks would otherwise re-render pixels already on screen.
        if frame.buffer === lastRenderedBuffer, frame.position == lastRenderedPosition {
            return
        }
        // Mirror by the camera that produced these pixels: across a flip, the
        // setting has already changed while this frame is still the old camera's.
        let orientation: CGImagePropertyOrientation =
            frame.position == .front ? .upMirrored : .up
        let image = CIImage(cvPixelBuffer: frame.buffer).oriented(orientation)
        guard image.extent.width > 0, image.extent.height > 0 else { return }

        let didRender = metalLayer != nil ? renderOnGPU(image) : renderThroughCoreGraphics(image)
        guard didRender else { return }

        lastRenderedBuffer = frame.buffer
        lastRenderedPosition = frame.position
        if !hasRenderedFrame {
            hasRenderedFrame = true
            onFirstFrame?()
        }
    }

    /// Renders straight into the next drawable. Nothing crosses to the CPU: Core
    /// Image encodes into the same command buffer that presents the frame.
    private func renderOnGPU(_ image: CIImage) -> Bool {
        guard let metalLayer, let stack = Self.metalStack else { return false }
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return false }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = stack.commandQueue.makeCommandBuffer() else { return false }
        stack.ciContext.render(aspectFilled(image, into: drawableSize),
                               to: drawable.texture,
                               commandBuffer: commandBuffer,
                               bounds: CGRect(origin: .zero, size: drawableSize),
                               colorSpace: Self.displayColorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Revealed only now that the drawable holds a real frame.
        if metalLayer.isHidden { metalLayer.isHidden = false }
        return true
    }

    /// Simulator path: no Metal device, so render to a CGImage and hand it to the
    /// layer. Sized to the layer rather than the sensor, and never upscaled.
    private func renderThroughCoreGraphics(_ image: CIImage) -> Bool {
        let extent = image.extent
        let pixelWidth = bounds.width * layer.contentsScale
        let pixelHeight = bounds.height * layer.contentsScale
        var rendered = image
        if pixelWidth > 0, pixelHeight > 0 {
            let fill = min(1, max(pixelWidth / extent.width, pixelHeight / extent.height))
            if fill < 1 {
                rendered = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            }
        }
        guard let cgImage = Self.fallbackContext.createCGImage(rendered,
                                                               from: rendered.extent) else {
            return false
        }
        layer.contents = cgImage
        return true
    }

    /// Scales and centers `image` so it covers `target` exactly, matching what
    /// `contentsGravity = .resizeAspectFill` used to do for the CGImage path.
    private func aspectFilled(_ image: CIImage, into target: CGSize) -> CIImage {
        let extent = image.extent
        let scale = max(target.width / extent.width, target.height / extent.height)
        let width = extent.width * scale
        let height = extent.height * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (target.width - width) / 2 - extent.minX * scale,
                y: (target.height - height) / 2 - extent.minY * scale
            ))
    }
}
