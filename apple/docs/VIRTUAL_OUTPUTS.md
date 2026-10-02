# Virtual outputs: implementation and qualification

## Camera (#172)

Stream ships the source for a public Core Media I/O camera system extension,
embedded at `StreamMac.app/Contents/Library/SystemExtensions/`. It publishes
**Stream Studio Camera** with a stable device UUID and two source formats:
1280 × 720 and 1920 × 1080, BGRA, 30 fps. Camera clients choose the source
format. The studio independently chooses its input format and composed Program
or destination canvas, fitting and letterboxing rather than changing the graph.

`StreamController.virtualCameraOutput` owns independent graph demand and profile
ownership. Embed `VirtualCameraOutputView(output: controller.virtualCameraOutput)`
in the main window's output controls. Start/stop does not start publishing or
recording. Preview may stop while this output keeps the composition running.
Stop this optional output with `controller.stopVirtualCameraOutput()` during
termination or other explicit teardown. Sleep, screen lock and user switching
stop it; returning does not automatically resume it. Project switching is gated
while it owns output demand, like the other production outputs.

### IPC, timestamps and bounds

The host sends timestamped samples through the **public CMIO sink stream**:
`CMIOStreamCopyBufferQueue`, `CMSimpleQueueEnqueue`, and `CMIODeviceStartStream`.
The extension calls `consumeSampleBuffer` and acknowledges scheduled output.
Apple manages the cross-process transport. This matters because its extension
runs as `_cmiodalassistants`, with a stricter sandbox than a foreground app.
There is no custom foreground-user socket, shared-file permission assumption,
or legacy DAL plug-in.

The graph subscription holds one frame, the CMIO sink queue holds two, and the
extension holds one newest valid frame. Only one asynchronous consume is in
flight. The producer pool has four buffers; the source caches two pools with
three buffers each. Exhaustion drops this output's frames. A stalled consumer
cannot accumulate tasks or stall other subscribers. The producer is restricted
to the signed `com.joeblau.StreamMac` process from the configured developer team;
other camera readers are mediated by the system's camera privacy controls.

New samples preserve the graph's host-clock PTS. Repeated frames and black
fallback advance monotonically on that same clock. Invalid, duplicate, stale,
future or oversized inputs are refused. With no producer, clients continue to
receive black video at the negotiated cadence. Disconnect clears the newest
frame; a producer crash or stalled feed ages to black within 500 ms. The camera
is video only and makes no claim about a linked audio device or A/V sync in
conferencing clients.

### Signing, activation and distribution

The host has `com.apple.developer.system-extension.install`; both bundles have
the sandbox and a dedicated macOS App Group:
`$(DEVELOPMENT_TEAM).com.joeblau.Stream.VirtualOutputs`. Its Mach service is
`$(DEVELOPMENT_TEAM).com.joeblau.Stream.VirtualOutputs.CameraExtension`, within
that group namespace. `DEVELOPMENT_TEAM` must match the actual signature on both
bundles. The legacy iOS group/keychain entitlements are preserved separately.
Apple supports this team-prefixed macOS group without registration or an App
Group provisioning profile; other restricted host entitlements still need
their appropriate provisioning profile.

The extension uses only composed frames, so it does not request camera or
microphone hardware access itself. Its entry point calls
`CMIOExtensionProvider.startService`. The host submits public
`OSSystemExtensionRequest` activation/deactivation **only when the operator
presses the corresponding button**. A signed app must reside in `/Applications`;
macOS may require administrator approval or a restart. The UI keeps request
state separate from actual device discovery. Activation success does not
invent device availability or receiving-app compatibility. An explicit
activation request may replace the embedded extension with the same or a newer
version; it refuses a downgrade. Use the public deactivation button for removal.

For Developer ID distribution, archive/sign the extension and host with matching
identities, preserve their entitlements, notarize and staple the enclosing app,
and qualify installation/updates/removal from `/Applications` on Apple silicon
and Intel. The extension target accepts `STREAM_CAMERA_PROVISIONING_PROFILE`
when the release configuration requires an explicit profile; the host accepts
`STREAM_MAC_PROVISIONING_PROFILE`. Camera extensions also have an Apple-supported
App Store route, subject to the entire app's review/distribution eligibility.
No install, OS approval, notarization, global driver change or SIP change is
performed by the build or validation scripts.

### Reproduce software validation

```sh
apple/scripts/run_studio_virtual_camera_harness.zsh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  apple/scripts/run_studio_virtual_camera_harness.zsh
xcodegen generate --spec apple/project.yml
xcodebuild -project apple/Stream.xcodeproj -scheme StreamMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The native harness constructs the **actual** CMIO provider/device/source/sink,
checks queue properties, negotiates formats, inspects rendered pixel buffers and
timestamps, holds buffers to force pool exhaustion, rejects invalid formats and
an unsigned producer, and checks stale/disconnect black fallback. It does not
install or start a system extension service and therefore does not qualify
the OS proxy, signed producer authentication, or receiving apps. Both Xcode
26.6 and 27.2 compile and run this native fixture; the embedded extension and
host compile together in the unsigned app build.

**Remaining acceptance gates:** restore release signing/provisioning and
notarization credentials; sign/install/activate the embedded camera; verify the
real sink/source IPC and permissions; select and receive it in current Zoom,
Safari/Chromium browsers and FaceTime; measure timestamps, duration, frame
loss, CPU/memory and client disconnect/exhaustion behavior; qualify update,
removal, sleep/wake and multiuser behavior on supported CPU architectures.
#172 remains open until those gates pass.

## Microphone (#173 / #174)

A CMIO camera extension does **not** create a virtual microphone. Apple's
AudioDriverKit sample directs virtual devices to an **Audio Server Driver
Plug-in**, rather than its hardware-driver path. A separate `.driver` bundle
loaded by Core Audio is the current prototype route. Its device must be proven
in another application's input selector, with program audio and lifecycle
measurements, before #174 can claim a validated distributable implementation.
System-wide HAL installation, signed packaging, permission and client tests
remain separate from camera extension activation. No microphone feature is
advertised merely because the camera compiles or activates.

## Primary sources

- [Apple: creating a camera extension](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [Apple WWDC: camera extensions, role-user sandbox, source/sink IPC](https://developer.apple.com/videos/play/wwdc2022/10022/)
- [Apple: accessing macOS App Group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
- [Apple: creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Apple: creating an audio device driver](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)
