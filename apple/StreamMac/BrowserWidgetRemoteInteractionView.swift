import AppKit
import CoreImage

/// Inspector surface for the SAME helper page. It displays the latest bounded frame and forwards
/// local deliberate input; it owns no WebKit page and never posts global or accessibility events.
@MainActor final class BrowserWidgetRemoteInteractionView: NSView {
    private weak var host: BrowserOverlayHost?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var lastMotion = 0.0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(host: BrowserOverlayHost, pixelSize: CGSize) {
        self.host = host
        super.init(frame: NSRect(origin: .zero, size: pixelSize))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let host, let buffer = BrowserOverlayFrameStore.shared.latest(for: host.storeKey),
              let image = imageContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(origin: .zero, size: frame.size)),
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds); context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); forward(event, kind: .mouseDown) }
    override func mouseUp(with event: NSEvent) { forward(event, kind: .mouseUp) }
    override func mouseDragged(with event: NSEvent) { forward(event, kind: .mouseDragged, throttle: true) }
    override func mouseMoved(with event: NSEvent) { forward(event, kind: .mouseMoved, throttle: true) }
    override func scrollWheel(with event: NSEvent) { forward(event, kind: .scroll, throttle: true) }
    override func keyDown(with event: NSEvent) { forward(event, kind: .keyDown) }
    override func keyUp(with event: NSEvent) { forward(event, kind: .keyUp) }
    private func forward(_ event: NSEvent, kind: BrowserWidgetInteraction.Kind, throttle: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if throttle { guard now - lastMotion >= 1.0 / 60 else { return }; lastMotion = now }
        let point = convert(event.locationInWindow, from: nil)
        let isKey = kind == .keyDown || kind == .keyUp
        let isScroll = kind == .scroll
        let input = BrowserWidgetInteraction(kind: kind, x: max(0, min(bounds.width, point.x)),
            y: max(0, min(bounds.height, point.y)), deltaX: isScroll ? max(-1_000, min(1_000, event.scrollingDeltaX)) : 0,
            deltaY: isScroll ? max(-1_000, min(1_000, event.scrollingDeltaY)) : 0, keyCode: isKey ? event.keyCode : 0,
            text: isKey ? (event.characters ?? "") : "", modifiers: UInt64(event.modifierFlags.rawValue) & 0x1f0000)
        host?.forwardHelperInteraction(input)
    }
}
