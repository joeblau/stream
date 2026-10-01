import SwiftUI

/// One labeled studio monitor (W03, issue #66): PREVIEW shows the staged
/// composition (what edits mutate and Take publishes), PROGRAM shows the
/// outgoing composition the outputs emit. The label is persistent — a monitor
/// is always identifiable — and the accent ring carries status: yellow on
/// preview while staged edits are unpublished, red on program while live.
///
/// S04 (issue #72): an optional `overlay` receives the FITTED IMAGE RECT in
/// local coordinates, so preview-only chrome (canvas selection, handles, snap
/// guides) can draw directly over the monitor image — in SwiftUI, never in
/// the engine's composed frames. The PROGRAM monitor uses the default empty
/// overlay and stays read-only.
struct PreviewView<Overlay: View>: View {
    let image: CGImage?
    let label: String
    /// Status ring + label chip color.
    var accent: Color = Color.secondary.opacity(0.3)
    /// Emphasized ring (pending edits / live) vs the idle thin ring.
    var isHighlighted = false
    /// Placeholder text while no frames are flowing.
    var placeholder = "Preview off"
    /// Preview-only chrome drawn over the image; gets the fitted image rect.
    var overlay: (CGRect) -> Overlay

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                    }
                }
                overlay(fittedImageRect(in: geometry.size))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(accent, lineWidth: isHighlighted ? 2 : 1)
            )
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption.weight(.bold))
                    .tracking(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(isHighlighted ? accent : .primary)
                    .padding(10)
            }
        }
    }

    /// The rect the aspect-fit image occupies inside the monitor — the
    /// coordinate anchor for canvas overlays. Zero while no image is flowing.
    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0,
              size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(image.width),
                        size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2,
                      y: (size.height - height) / 2,
                      width: width, height: height)
    }
}

extension PreviewView where Overlay == EmptyView {
    /// The read-only monitor initializer (PROGRAM, and any monitor without
    /// canvas chrome).
    init(image: CGImage?,
         label: String,
         accent: Color = Color.secondary.opacity(0.3),
         isHighlighted: Bool = false,
         placeholder: String = "Preview off") {
        self.init(image: image, label: label, accent: accent,
                  isHighlighted: isHighlighted, placeholder: placeholder,
                  overlay: { _ in EmptyView() })
    }
}
