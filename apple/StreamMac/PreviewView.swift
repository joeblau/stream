import SwiftUI

/// One labeled studio monitor (W03, issue #66): PREVIEW shows the staged
/// composition (what edits mutate and Take publishes), PROGRAM shows the
/// outgoing composition the outputs emit. The label is persistent — a monitor
/// is always identifiable — and the accent ring carries status: yellow on
/// preview while staged edits are unpublished, red on program while live.
struct PreviewView: View {
    let image: CGImage?
    let label: String
    /// Status ring + label chip color.
    var accent: Color = Color.secondary.opacity(0.3)
    /// Emphasized ring (pending edits / live) vs the idle thin ring.
    var isHighlighted = false
    /// Placeholder text while no frames are flowing.
    var placeholder = "Preview off"

    var body: some View {
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
        }
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
