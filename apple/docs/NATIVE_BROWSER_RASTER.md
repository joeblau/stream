# Native browser widget raster qualification

The production in-app browser host and the disabled independent-audio helper use
one public PDF rasterizer for widget pixels. `WKPDFConfiguration.rect` selects the
viewport, and `allowTransparentBackground = true` preserves transparent DOM
content. The latter property is public on macOS 14+, as declared by the installed
WebKit SDK. A serial background queue draws the PDF into a cleared, premultiplied
BGRA CoreGraphics bitmap. No private background KVC, screen capture, permission
request or activation is needed by this renderer. Apple's references are
[`allowTransparentBackground`](https://developer.apple.com/documentation/webkit/wkpdfconfiguration/allowtransparentbackground)
and [`createPDF(configuration:completionHandler:)`](https://developer.apple.com/documentation/webkit/wkwebview/createpdf(configuration:completionhandler:)).

The earlier public `WKSnapshotConfiguration` experiment produced an opaque white
background with both normal and public nonopaque NSView configurations. That
negative result is retained in [the audio research history](research/browser-widget-audio.md).
The new path preserves actual alpha; it does not remove white pixels afterward.
The separate, unmounted `BrowserOverlayPrototype.swift` experiment is unchanged.

## Bounds and callback ownership

The process admits eight physical PDF/raster jobs, at most one per WKWebView,
and eight waiting intents, coalesced to the latest per waiting view. The oldest
intent that fits the remaining budget runs first. A queued large viewport cannot
block healthy smaller peers. Outstanding raster reservations are capped at
29,260,800 pixels: one maximum legacy 3840×3840 viewport plus seven 1920×1080
peers, equivalent to 111.6 MiB of BGRA destinations. Dimensions remain 16…3840
per axis for the legacy host. These are admission limits, not a promise of useful
frame rate for every supported dimension.

Accepted PDFs are capped at 16 MiB each (128 MiB across eight jobs), exactly one
page, zero rotation, and an exact origin-zero media box matching the requested
viewport. Those checks precede destination allocation. WebKit produces the PDF
before its byte length can be inspected; oversized replies are rejected on
arrival. These limits exclude WebKit's own process memory, frame stores, image
copies, composition and recording buffers.

A stalled callback retains its physical and pixel reservations until actual
completion. Logical Stop/Reload never invents cancellation or releases that
reservation early. One stalled largest viewport still leaves room for seven HD
clients. Authority is checked before admission, at PDF completion and after the
background raster completes. The helper additionally checks exact WKWebView
identity and page generation. Late pixels cannot restore a stopped or replaced
page. The helper keeps its existing narrower two-frame writer cap, 1920×1080
viewport cap, request IDs, deadlines and exact-PID frame IPC.

## Measured qualification, 2026-10-21

These are local M3 Max / Mac15,8 results on macOS 27.2 (26B118), Xcode 27.2
(27B5038j), with a logged-in WindowServer session. No capture grant was requested.

| Actual check | Result |
| --- | --- |
| Transparent, half-green, red and opaque-white DOM pixels | Premultiplied BGRA `[0,0,0,0]`, `[0,128,0,128]`, `[0,0,255,255]`, `[255,255,255,255]` |
| Immediate script-updated 2D canvas and screen CSS | Current cyan/orange canvas preserved; screen blue retained despite yellow `@media print` rule |
| Local muted H264 video, preserved/default-buffer WebGL, CSS animation | Actual seeks, looped playback and successive animation/script colors retained |
| Eight actual legacy hosts at 1920×1080 / requested 15 fps | All eight exceed ten additional fresh frames over a two-second interval after warmup; the runner prints cumulative counts and interval deltas separately |
| One held maximum viewport, another maximum viewport queued ahead of HD clients | Seven healthy HD clients finish while held callback retains ownership; stale queued/completed work refuses pixels |
| Helper IPC and current/stale Suspend, Resume, Stop | Exact helper pixels retain alpha; old commands cannot retire the blue replacement page |
| Actual legacy/helper → Program composition → shipping Program writer → native H264 decode | Raw magenta preserved exactly, half-green blends correctly, red/white content retained; decoded background matches pre-widget same-codec baseline within existing 12-level tolerance |
| Helper image → H264/AAC file with synthetic stereo 1000 Hz PCM | 30 video frames / 96,000 PCM source frames; native decode retains image and approximately 0.1 tone amplitude |
| Malformed/oversized PDF, multiple pages, wrong media box, overflowing dimensions | Rejected without allocating the requested destination |

Twenty repeated 1920×1080 PDF→CGImage samples measured about 6.3 ms mean,
8.4 ms maximum in the final bounded-admission qualification run. Timing includes
public WebKit PDF completion and CG raster; it is neither a hardware guarantee
nor a measured browser-media presentation timestamp. The fixture prints every
sample for repeat comparison. The eight-host run establishes bounded short-run
progress, not a long-duration workload qualification.

The H264/AAC alpha test compares the composited corner with an opaque magenta
reference in the same encoded frame, preserving the existing 12-level codec
tolerance. This avoids confusing codec color conversion with lost transparency:
canonical raw magenta `[255,0,255]` decoded as `[247,0,234]` for both patches.
The independent actual Program-writer test also compares the background before
and after the web layer enters. Raw composition must preserve the corner exactly.

## Repeatable fixtures and remaining gates

From `apple/`, run:

```sh
scripts/run_browser_widget_pdf_raster_harness.zsh
scripts/run_browser_widget_pdf_media_harness.zsh
scripts/run_browser_snapshot_alpha_harness.zsh
STREAM_VENDOR_ROOT=/path/to/clean/vendor scripts/run_browser_widget_pdf_program_harness.zsh
```

The media fixture needs ffmpeg and public WebGL support; unavailable WebGL exits
77 explicitly unqualified. The Program fixture builds the actual native graph
with isolated defaults and inert capture/credential boundaries, and launches the
owned ad hoc helper through LaunchServices. It uses silent local HTML and an
inert qualification audio driver. It never starts microphone/camera/system
capture. `BROWSER_PDF_PROGRAM_DERIVED` selects an existing compatible derived
directory; its transport archive must pass the existing relay-policy check.

Outputs live in `build/browser-widget-pdf-{validation,media-validation,program-validation}`
and `build/browser-snapshot-alpha-validation`; the runners print actual files,
counts and timing receipts. Native CI runs the four fixtures and retains logs and
generated media. Unsupported CI graphics/WindowServer environments remain a
qualification failure rather than being reported as a passed content probe.

DRM/protected video, arbitrary streaming widgets, complex WebGL effects, arbitrary
high-resolution content, long-duration eight-client behavior and other OS/GPU
combinations remain unqualified. PDF is an image sampling path; it cannot promise
frame-perfect timing with browser audio. The product independent-audio route
remains disabled (`productionRouteQualified == false`). Operator strip/ISO wiring
is documented separately in [browser widget operator controls](research/browser-widget-operator-controls.md);
signed/sandboxed helper IPC, actual audio attribution/retirement/exclusion,
permission lifecycle and new live same-page A/V proofs remain required before
that route is enabled. This pixel qualification does not close #124.
