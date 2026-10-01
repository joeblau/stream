# NDI and DeckLink capture prerequisites

C06 #160 and C07 #161 remain open. No working SDK capture bridge or hardware qualification is claimed.

`apple/scripts/run_pro_input_prerequisites.zsh` compiles a read-only Swift diagnostic. It checks vendor headers/runtime paths, loader/symbol availability, NDI's runtime version when available, and the current process's Screen Recording access. Optional environment variables select SDK/runtime locations: `STREAM_NDI_SDK_ROOT`, `STREAM_NDI_RUNTIME`, `STREAM_DECKLINK_SDK_ROOT`, and `STREAM_DECKLINK_RUNTIME`.

On this workspace, macOS 27.0 (26A428), both SDK headers and both runtimes are missing, and Screen Recording preflight returns false. Standard Blackmagic installation locations are absent; the USB/Thunderbolt probe did not expose a Blackmagic device. These are prerequisite observations, not proof that every possible vendor installation path or PCI device is absent. Capture, timestamp synchronization, tally, signal loss and reconnect have not been tested.

## Version and distribution candidates

NDI's current [SDK licensing page](https://docs.ndi.video/all/developing-with-ndi/sdk/licensing) identifies SDK 6.3.2. The downloaded SDK agreement must be checked before selecting a distributable artifact. That page requires nearby NDI links and trademark attribution, forbids redistributing the tools themselves, and directs applications to keep bundled libraries within their own application folders. Record the actual SDK/runtime version and hashes, architecture slices, third-party notices, and the intended distribution channel before packaging. No vendor binaries are added by this change.

Blackmagic publishes [Desktop Video SDK 16.0 and Desktop Video 16.4](https://www.blackmagicdesign.com/developer/products/capture-and-playback/sdk-and-software). These are qualification candidates, not a tested version pair. The [SDK overview](https://sdk-doc.blackmagicdesign.com/decklink-sdk/) describes runtime libraries installed with the product installer and dynamic linkage from SDK-based applications. Use the SDK's actual headers/dispatch sources to build the bridge; do not reproduce a guessed C++ COM ABI in Swift.

Blackmagic's [macOS sandbox requirements](https://sdk-doc.blackmagicdesign.com/decklink-sdk/sandboxing.html) include Mach lookup for `com.blackmagic-design.desktopvideo.DeckLinkHardwareXPCService` and read-only preference access for `com.blackmagic-design.desktopvideo.prefspanel`. Verify the exact values against the SDK sample entitlements, and qualify signed sandboxed and intended distribution builds. This work does not add untested entitlement exceptions.

## Native bridge work after prerequisites exist

One registry SourceDefinition owns one adapter session across every scene, preview and program reference. Vendor callbacks/receive loops stay off the compositor tick. Copy or retain SDK-owned media only for a bounded interval, normalize source timestamps onto the studio host clock, publish latest video through the existing frame holders, and feed audio through the mixer source channel. No renderer wait or synchronous discovery is allowed.

For NDI, select an explicit discovery result and preserve its identity. The [receive API](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-recv) supports BGRA/BGRX reception, bounded capture timeouts, audio/video/metadata frame release, automatic reconnect, queue/drop telemetry, and retained preview/program tally. Start with progressive BGRA/BGRX plus PCM audio, reject unqualified formats inline, and prove timestamp mapping and alpha handling before enabling other formats. Keep separate preview/program demand for tally; do not infer it from whichever scene was last selected.

For DeckLink, persist hardware identity and selected input/format. The [capture flow](https://sdk-doc.blackmagicdesign.com/decklink-sdk/HighLevel/capture.html) enumerates modes, checks supported mode/pixel-format combinations, enables video/audio and starts callbacks. Convert callback buffers into the app's bounded holders, preserving video stream time and audio packet time. Report missing driver, unsupported mode, no signal, and reconnect inline without switching to a different device.

Qualification must record one real sender/device configuration, OS/toolchain, SDK/runtime/driver version, frame format/rate/audio layout, and signed-app permissions. Test removal/reappearance, signal loss, mode changes, denied access, shared scene references, queue/drop bounds and unrelated-stream continuity. Until those inputs are available these tasks cannot satisfy their capture acceptance criteria.
