# Native chroma key and LUT implementation

Implemented for E02 #107 and E04 #108. Both tasks retain their remaining qualification gates.

Chroma key uses an encoded-sRGB, 64³ premultiplied RGBA table. Chroma direction tolerates screen lighting variation; saturation protects pale neutral detail. Neutral custom colors use RGB distance. Smoothstep softness preserves fractional alpha, and spill suppression desaturates key-aligned edge colors while retaining luminance. A normalized source-space garbage rectangle and optional feather run before framing. Source defaults and staged layer overrides retain the existing effect scope; bypass preserves settings.

LUT import supports UTF-8 SDR 3D `.cube`, dimensions 2–64, RGB outputs/domain 0–1, comments, a quoted title, BOM, and scientific notation. Unsupported 1D/shaper/log/HDR ranges, duplicate headers, incorrect row counts, nonfinite values, and files over 16 MiB are rejected. Red varies fastest. Identity is blended into the table for intensity; texel alpha is one. LUT processing follows the existing picture adjustments with explicit sRGB/linear-sRGB selection. LUTs are copied into Assets and referenced by stable AssetID; repair preserves that ID. Usage tracks scenes, source defaults, presets, and staged/program snapshots.

The GPU path uses [Apple's CIColorCubeWithColorSpace](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/#//apple_ref/doc/filter/ci/CIColorCubeWithColorSpace), with the cube's color space set explicitly. Apple documents premultiplied table data and a red/green/blue indexing order for [CIColorCube](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/#//apple_ref/doc/filter/ci/CIColorCube); the native filter handles color-space conversion around the transform.

All parsing and table preparation runs off the render tick. A shared worker permits four pending tables, with a 64 MiB/32-entry LRU cache. Loading permits four files at once and at most 32 source LUTs. Missing/loading/invalid tables render the original image and produce an inspector status. Preview/program share prepared data. Motion matching falls back if chroma/LUT configurations differ.

## Evidence and outstanding gates

On this macOS 27 arm64 workspace, six core tests pass, including green/blue/neutral keys, lighting variation, existing alpha, soft edges/spill, malformed/unsupported files, table ordering, and intensity. The native app and actual-source harness compile. `scripts/run_color_transform_harness.zsh` tests the cache and creates synthetic CPU-reference before/keyed/composite PNGs; it additionally tests native CI alpha, a channel-swapping LUT, and bypass when the CI control renders correctly.

The restricted workspace renders an opaque solid-red CI control as all-zero bytes. Native CI/GPU pixel comparisons and sustained live-footage render cost are therefore explicitly skipped, not passed. E02 still needs representative hair/edge footage and a live camera on an unrestricted supported Mac. E04 still needs native color/alpha qualification and referenced-asset packaging through P04 #155, whose show-export workflow remains open.
