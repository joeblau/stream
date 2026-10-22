# Native chroma key and LUT implementation

Implemented for E02 #107 and E04 #108. Both tasks retain their remaining qualification gates.

Chroma key uses an encoded-sRGB, 64³ premultiplied RGBA table. Chroma direction tolerates screen lighting variation; saturation protects pale neutral detail. Neutral custom colors use RGB distance. Smoothstep softness preserves fractional alpha, and spill suppression desaturates key-aligned edge colors while retaining luminance. A normalized source-space garbage rectangle and optional feather run before framing. Source defaults and staged layer overrides retain the existing effect scope; bypass preserves settings.

LUT import supports UTF-8 SDR 3D `.cube`, dimensions 2–64, RGB outputs/domain 0–1, comments, a quoted title, BOM, and scientific notation. Unsupported 1D/shaper/log/HDR ranges, duplicate headers, incorrect row counts, nonfinite values, and files over 16 MiB are rejected. Red varies fastest. Identity is blended into the table for intensity; texel alpha is one. LUT processing follows the existing picture adjustments with explicit sRGB/linear-sRGB selection. LUTs are copied into Assets and referenced by stable AssetID; repair preserves that ID. Usage tracks scenes, source defaults, presets, and staged/program snapshots.

The shipping compositor deliberately disables implicit Core Image working-space conversion. Merely setting `CIColorCubeWithColorSpace.inputColorSpace` in that context produced identical sRGB and linear-sRGB results. The LUT boundary now explicitly applies [sRGB-to-linear](https://developer.apple.com/documentation/coreimage/cisrgbtonecurvetolinear) and [linear-to-sRGB](https://developer.apple.com/documentation/coreimage/cilineartosrgbtonecurve) transfer filters around a raw `CIColorCube` for linear LUTs; encoded-sRGB LUTs and chroma cubes remain encoded. Apple documents premultiplied table data and red/green/blue indexing for [CIColorCube](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/#//apple_ref/doc/filter/ci/CIColorCube).

Small linear LUTs also need a denser interpolation grid: an unprepared two-texel identity LUT rounded sRGB 0.01 and 0.02 shadows to black after the transfer round trip on the tested Metal device. The worker upsamples small linear tables to an aligned grid of 32–64 texels per side. Every original knot remains a knot, preserving the original piecewise trilinear transform and linear-space intensity blend. Preparation remains off the render tick, bounded by 64³ RGBA float texels (4 MiB). Cache identity includes the chosen color space. No global compositor color policy changes.

All parsing and table preparation runs off the render tick. A shared worker permits four pending tables, with a 64 MiB/32-entry LRU cache. Loading permits four files at once and at most 32 source LUTs. Missing/loading/invalid tables render the original image and produce an inspector status. Preview/program share prepared data. Motion matching falls back if chroma/LUT configurations differ.

## Evidence and outstanding gates

The 2026-10-02 baseline on macOS 27 arm64 passed six core tests, including green/blue/neutral keys, lighting variation, existing alpha, soft edges/spill, malformed/unsupported files, table ordering, and intensity. That baseline native app and actual-source harness compiled. Its synthetic CPU before/keyed/composite images and channel-swapping LUT were initial checks; the current mandatory Metal and photographed sequence checks below supersede their coverage limits.

The unrestricted macOS 27.0.1 arm64 run on 2026-10-02, built with Xcode 26.6, passes the native CI control and all native key/alpha, LUT channel-order/intensity/color-space and bypass comparisons. The 64³ chroma table prepared off the render thread in 0.206 seconds. Synthetic CPU reference composition contains 1,011 fractional-alpha edge pixels. The earlier restricted workspace rendered even an opaque red control as zero bytes; that earlier skipped qualification is superseded by this actual native run.

The workspace integration fixture also exports, imports and parses real LUT bytes, verifies stable remapped effect/asset references, and preserves remapped text comment slots. This portable-show integration is in PR #189. E02/E04 still need representative hair/edge footage, physical camera color inspection and sustained render-cost qualification; synthetic fixtures do not establish those results.


## Metal qualification on photographed footage (2026-10-22)

The current harness requires a real Metal device and fails its solid-color control instead of accepting a software fallback. It exercises the shipping `ColorTransformRenderer` and `SceneRenderer`, including nonlinear color-space discrimination, fractional alpha, small-linear-LUT shadow identity, intensity/bypass, source-space garbage-mask coordinates, mask-before-framing, picture-before-LUT order and image/video backgrounds. The order test deliberately uses transforms that do not commute. Seven focused Core tests include aligned-grid knot preservation, intensity, validation and bounded prepared-table size.

The optional photographed fixture downloads **48 consecutive original 1920 × 1012 OpenEXR camera plates**, frames `04_2a_00100`–`04_2a_00147`, from the [Xiph mirror of Blender's original footage](https://media.xiph.org/tearsofsteel/tearsofsteel-footage-exr/04_2a/linear_hd/). Attribution: **(CC) Blender Foundation | mango.blender.org**, [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/), verified against the publisher's [license notice](https://media.xiph.org/tearsofsteel/README.txt) and [original-plate description](https://media.xiph.org/tearsofsteel/linear-exr/README.txt). Every original byte count and SHA-256 hash is pinned in `scripts/fixtures/color-footage-manifest.json`. No footage is bundled with the application or committed to the repository.

These are photographed people, hair, clothing, lighting variation and motion, with the original green-screen background. They are not a synthetic subject placed over generated green. The fixture interprets the scene-linear plates with Rec.709/sRGB primaries, clips to SDR and explicitly converts them to encoded-sRGB BGRA source buffers. Generated comparison PNGs and JSON measurements retain an `ATTRIBUTION.txt` describing those changes. This tests the product's SDR contract; it does not establish HDR or camera-driver qualification.

The independent analytic chroma oracle samples the decoded photographed pixels. Each frame retains fractional hair-region samples, opaque foreground and transparent background; per-frame and consecutive-frame matte errors, positive green-spill reduction and premultiplied-alpha bounds are measured. The selected hair region is fixed in top-left bitmap coordinates and covers the moving man's hair and its adjacent screen throughout the sequence. Image/video background and before/keyed/composite frames are generated through the actual renderer for inspection. The oracle measures implementation error, not a human-labeled ground-truth matte.

On the Apple M3 Max, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), all 48 frames passed. The stride-four grid retained 162–232 fractional-alpha hair-region samples per frame. Overall alpha mean absolute error was 0.005527; maximum per-frame overall p99 was 0.177913, while maximum hair-region p99 was 0.031178. Maximum consecutive-frame alpha-delta error was 0.009818. The average reduction of measured positive green excess in qualifying fractional-edge samples was 0.004439; it measures a control response rather than an artistic matte-quality score. Generated full-resolution frames were visually inspected.

The 64³ key table is an approximation. Initial diagnosis on frame 100 measured hair-region alpha-error p99 about 0.025, versus overall mean 0.00544 and overall p99 about 0.169; its largest errors occur at near-black chroma transitions. The fixture therefore applies a tighter hair-region bound separately and records the overall distribution. Inspecting the rendered plate also shows expected removal of similarly colored green foreground material and residual green edge spill at default settings. This is a useful stress fixture and does not claim a perfect matte for arbitrary lighting or clothing.

Reproduce with isolated dependencies if needed:

```sh
python3 apple/scripts/fetch_color_qualification_footage.py
COLOR_CORE_TESTS=1 \
COLOR_FOOTAGE_DIRECTORY="$PWD/apple/build/color-transform-footage" \
COLOR_SUSTAIN_SECONDS=60 \
zsh apple/scripts/run_color_transform_harness.zsh
```

The paced sustained run measures 1080p30 with 30 seconds of bypassed baseline and 60 seconds of combined key, source mask/feather, mirror/zoom, picture adjustments, a 64³ linear LUT at partial intensity and a moving video background. It warms each renderer before measuring, records wall/completion latency and deadline overruns, and reports actual sampled Core Image render-task kernel timing separately. A buffer lock forces completed destination pixels; it does not time only lazy image-graph construction. Kernel metrics include the warmup samples. `qualifies1080p30OnThisRun` is a local result, not a GPU-utilization estimate or universal device guarantee.

The reserved quiet-host run completed with these results on the device above (all latencies in milliseconds):

| Variant | Frames / seconds | Mean wall/completion | p95 | p99 | Maximum | Render / cadence misses | Sampled GPU mean | Local result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Effects bypassed | 900 / 30.006 | 4.522 | 6.232 | 8.455 | 147.205 | 2 / 5 | 0.261 (32 samples) | Does not qualify |
| Combined effects | 1,800 / 60.001 | 10.579 | 14.941 | 17.864 | 27.370 | 0 / 0 | 1.021 (62 samples) | Qualifies this run |

The baseline's scheduling spike remains in the artifact and result; it was not discarded. The processed run stayed within its 33.333 ms render budget for every measured frame. JSON output is `build/color-transform-validation/frames/sustained-metal-measurements.json`; the photographed error distribution is retained alongside it. This is a bounded local measurement, not a long broadcast, multi-source maximum-load or hardware-source endurance qualification.

A **live physical camera color/alpha/framing check remains unperformed**. This qualification neither opens a camera or microphone nor requests TCC grants. Both original issues retain that explicit hardware-source validation requirement.
