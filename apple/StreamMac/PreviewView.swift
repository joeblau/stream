import SwiftUI

/// The program/preview monitor: shows the controller's latest composited frame
/// aspect-fit on black, or a standby placeholder until the preview is running.
struct PreviewView: View {
    @ObservedObject var controller: StreamController

    var body: some View {
        ZStack {
            Color.black
            if let image = controller.previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(controller.isPreviewing ? "Waiting for sources…" : "Preview off")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(controller.isLive ? Color.red : Color.secondary.opacity(0.3),
                              lineWidth: controller.isLive ? 2 : 1)
        )
    }
}
