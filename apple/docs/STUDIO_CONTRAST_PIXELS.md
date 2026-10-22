# Native studio contrast pixel proof

The owned native contrast view passes the original red, black and white pixel
gates with the actual production `StudioAccessibility.swift` styles. This fixes
a fixture sampling error; no production interface or color policy changes.
The [dated receipt](STUDIO_CONTRAST_PIXELS_2026-10-22.json) binds the complete
source, exact extracted methods, executable, logs and retained images.

The earlier red-reference failure did not mean the host failed to render red.
Its retained 600×200 PNG has an embedded display ICC profile and stores the
reference as RGBA `(234, 51, 35, 255)`. Independent profile-aware decoding and
the actual native Core Graphics destination both identify that as red. The
paired native replay confirms the old `NSBitmapImageRep.colorAt` / `NSColor`
sampling route reports approximately `(0.944, 0.293, 0.178)`, while the explicit
sRGB destination contains `(255, 2, 0, 255)` for the archived image. Reading
normalized bytes avoids interpreting the colors again through that route.

For the actual native view, both standard and increased contrast preserve the
red media reference as `(255, 0, 0, 255)` in the sRGB destination. Increased
contrast renders the panel opaque black and changes the white secondary-text
pixel count from 0 to 3,000. All original numeric thresholds remain unchanged.
Independent known-red and known-green byte controls respectively pass and fail
the same red gate. Raw native and normalized PNGs are retained before assertions.

The lean tool compiles the entire unchanged production style file and verbatim
view, method, assertion and isolated-defaults slices from the workspace fixture.
Its only application entry creates the owned `NSApplication` and contrast view;
it constructs no workspace, media engine, capture, device or provider graph.
The fixture uses the original 20-point text and reduced-motion configuration in
its own temporary preference suite. It does not change operating-system settings,
TCC, VoiceOver or application activation.

```sh
python3 scripts/run_studio_contrast_harness.py \
  --output /absolute/fresh/owned/output \
  --profile-reference /absolute/path/to/the/retained/owned/reference.png
```

Use the shared native build-slot wrapper. The runner requires a fresh output
directory, uses two Swift jobs, bounds compilation to 120 seconds and runtime
to 30 seconds, and records failures. The first initializer compile failure,
two pre-window sampler failures and a generator-boundary failure are preserved.
The corrected source's first actual standard/increased view attempt passed.

This proves the owned style contrast boundary. It does not prove the complete
SwiftUI accessibility tree, labels/actions/order, native key routing or every
control's layout in the full small window. Those original #90 requirements
remain separate; no manual-listening or physical-keyboard requirement is added.
