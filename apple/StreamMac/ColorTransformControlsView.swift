import AppKit
import SwiftUI
import StreamCore
import UniformTypeIdentifiers

struct ColorTransformControlsView: View {
    @Binding var effects: SourceEffects
    @EnvironmentObject private var dispatcher: StudioCommandDispatcher
    @State private var importError: String?
    @State private var importing = false
    @State private var showMask = false

    var body: some View {
        DisclosureGroup("Chroma Key") {
            Toggle("Enable Chroma Key", isOn: $effects.chromaKey.isEnabled)
            if effects.chromaKey.isEnabled {
                HStack {
                    ColorPicker("Key Color", selection: keyColor, supportsOpacity: false)
                    Button("Sample", systemImage: "eyedropper") {
                        NSColorSampler().show { color in
                            guard let color else { return }
                            effects.chromaKey.keyColorHex = hex(color)
                        }
                    }.help("Sample a key color from the desktop")
                }
                HStack {
                    Button("Green") { effects.chromaKey.keyColorHex = "#00FF00" }
                    Button("Blue") { effects.chromaKey.keyColorHex = "#0000FF" }
                }
                Slider(value: $effects.chromaKey.tolerance, in: 0...1) { Text("Tolerance") }
                Slider(value: $effects.chromaKey.softness, in: 0.001...1) { Text("Edge Softness") }
                Slider(value: $effects.chromaKey.spill, in: 0...1) { Text("Spill Suppression") }
                Toggle("Before / Bypass Key", isOn: $effects.chromaKey.isBypassed)
                Text("Compare before and after in Preview. Layer edits reach Program on Take; source defaults affect both.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Garbage Mask", isExpanded: $showMask) {
                    // Keep a positive source-space rectangle while dragging.
                    Slider(value: $effects.chromaKey.left, in: 0...max(0,0.99-effects.chromaKey.right)) { Text("Left") }
                    Slider(value: $effects.chromaKey.right, in: 0...max(0,0.99-effects.chromaKey.left)) { Text("Right") }
                    Slider(value: $effects.chromaKey.top, in: 0...max(0,0.99-effects.chromaKey.bottom)) { Text("Top") }
                    Slider(value: $effects.chromaKey.bottom, in: 0...max(0,0.99-effects.chromaKey.top)) { Text("Bottom") }
                    Slider(value: $effects.chromaKey.maskFeather, in: 0...32) { Text("Mask Feather") }
                }
                Text("Keying preserves transparency for the image/video/background layers below this source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        DisclosureGroup("Color LUT") {
            LUTStatusView(runtime: dispatcher.lutLibrary, id: effects.lut.assetID)
            Picker("LUT Asset", selection: $effects.lut.assetID) {
                Text("None").tag(nil as AssetID?)
                ForEach(dispatcher.assetLibrary.assets.filter { $0.fileName.lowercased().hasSuffix(".cube") }) { asset in
                    Text(asset.name).tag(Optional(asset.id))
                }
            }
            Button(importing ? "Importing…" : "Import .cube LUT…") { importLUT() }.disabled(importing)
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            if effects.lut.assetID != nil {
                Slider(value: $effects.lut.intensity, in: 0...1) { Text("LUT Intensity") }
                Picker("LUT Color Space", selection: $effects.lut.colorSpace) {
                    Text("sRGB").tag(LUTColorSpace.sRGB)
                    Text("Linear sRGB").tag(LUTColorSpace.linearSRGB)
                }
                Toggle("Before / Bypass LUT", isOn: $effects.lut.isBypassed)
                Text("Applied after picture adjustments. Imported LUTs are copied into project Assets; missing files can be restored there. Supported: SDR 3D .cube, size 2–64, domain 0–1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var keyColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(srgbRed: effects.chromaKey.color.x,
            green: effects.chromaKey.color.y, blue: effects.chromaKey.color.z, alpha: 1)) },
                set: { effects.chromaKey.keyColorHex = hex(NSColor($0)) })
    }
    private func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .green
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent*255).rounded()),
                      Int((rgb.greenComponent*255).rounded()), Int((rgb.blueComponent*255).rounded()))
    }
    private func importLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true; importError = nil
        Task { @MainActor in
            defer { importing = false }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                    return try CubeLUT.parse(file.read(upToCount: CubeLUT.maxFileBytes+1) ?? Data())
                }.value
                guard let asset = await dispatcher.assetLibrary.importFile(at: url, mode: .copy) else {
                    importError = "The LUT could not be copied into project Assets."; return
                }
                effects.lut.assetID = asset.id
            } catch { importError = String(describing: error) }
        }
    }
}

private struct LUTStatusView: View {
    @ObservedObject var runtime: LUTLibraryController
    let id: AssetID?
    var body: some View {
        if let id {
            switch runtime.statuses[id] {
            case .loading: Text("Loading LUT…").foregroundStyle(.secondary)
            case .ready(let size): Text("\(size)³ LUT ready — compare in Preview").foregroundStyle(.secondary)
            case .failed(let message): Text(message).foregroundStyle(.red)
            case nil: Text("Waiting for LUT…").foregroundStyle(.secondary)
            }
        }
    }
}
