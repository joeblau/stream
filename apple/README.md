# Stream

**Stream** is an iOS 27+ app that captures the screen and publishes it to RTMP,
RTMPS, SRT, or WHIP endpoints. It uses ScreenCaptureKit for system-managed content
selection and sample delivery; ReplayKit and a broadcast upload extension are not
used.

## Features

- System screen selection through `SCContentSharingPicker`.
- Screen, app-audio, and microphone samples through `SCStream`.
- RTMP/RTMPS publishing with HaishinKit, plus SRT and experimental WHIP support.
- Configurable resolution, bitrate, frame rate, codec, audio mix, and microphone gain.
- H.264 or HEVC encoding with VideoToolbox low-latency rate control.
- Optional facecam composited into the outgoing video.
- Restream unified chat.
- Connection credentials stored in the Keychain.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Stream` | SwiftUI interface, ScreenCaptureKit lifecycle, sample routing, and publishing |
| `StreamCore` | Settings, secure storage, liveness state, and recording utilities |
| `StreamBroadcast` | Process-agnostic publishers, network recovery, and facecam composition; these sources compile into the app target |

`ScreenCaptureController` presents `SCContentSharingPicker`, receives the selected
`SCContentFilter`, creates an `SCStream`, and forwards its screen/audio/microphone
buffers to the selected publisher. Capture and network publishing run in the app
process, as required by ScreenCaptureKit on iOS 27.

## Requirements

- Xcode 27 or newer.
- iOS 27 or newer on a physical device.
- XcodeGen (`brew install xcodegen`).
- An Apple Developer team for device signing.
- Apple's Multitasking Camera Access capability enabled for the Stream App ID so
  the facecam remains active during full-display capture.

The current Xcode 27 beta does not ship ScreenCaptureKit in the iOS Simulator SDK.
The app provides a simulator stub for previews and non-capture UI, but actual
screen capture must be tested on hardware.

## Build

```bash
git submodule update --init --recursive
cd apple
xcodegen generate
xcodebuild \
  -project Stream.xcodeproj \
  -scheme Stream \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Deploy to a paired iPhone

With one paired physical iPhone connected and unlocked, build, install, and
launch the app with:

```bash
bun stream
```

If more than one iPhone is available, select one explicitly with
`STREAM_DEVICE_ID=<UDID> bun stream`.

## Configure a stream

Open Settings and choose the transport:

- RTMPS: for example `rtmps://live.restream.io/live`, plus its stream key.
- RTMP: for example `rtmp://live.restream.io/live`, plus its stream key.
- SRT: enter the full SRT URL, including stream ID or passphrase query values.
- WHIP: enter the HTTPS WHIP endpoint and optional bearer token.

The URL and key are stored per protocol. The record button remains available when
configuration is incomplete, but capture will not start until the selected
transport is publishable.

## Start and stop

Tap the `record.circle` toolbar button. The app presents Apple's
`SCContentSharingPicker` for full-display selection. After selection, the button
changes to `stop.circle`; tap it to stop both `SCStream` and the network publisher.

The picker exposes microphone control. App-audio inclusion and microphone gain are
configured in Settings.

## Facecam

ScreenCaptureKit's system camera effect only supports current-application capture.
Stream captures the full display, so it retains its own low-resolution camera input
and composites that frame into the selected corner before encoding. The app uses
Apple's Multitasking Camera Access entitlement to keep that camera session active
after full-display sharing moves Stream into the background. If the installed
provisioning profile does not grant the capability, Settings reports that the
signed build cannot keep the facecam active.

## Codec selection

The Video settings offer H.264 (default) or HEVC. HEVC gives roughly a 40%
quality-per-bit gain on text-heavy screen content in the 2–8 Mbps band, but needs
a compatible ingest: it rides SRT (MPEG-TS) and *enhanced*-RTMP (the
publisher advertises the `hvc1` FourCC in the E-RTMP connect command). Traditional
RTMP services such as Restream and the current WHIP transport speak H.264 only, so
leave the codec on H.264 for them — HEVC over RTMP should be verified against the
specific endpoint on a real device. Low-latency VideoToolbox rate control is enabled
for both codecs.

## Notes

- ScreenCaptureKit is device-only in the current Xcode 27 beta SDK.
- Local backup remains disabled because it requires a second video encoder.
- WHIP should be validated on hardware because its WebRTC stack has a larger
  memory footprint than RTMP or SRT.
- The output resolution locks to the first captured frame's aspect ratio. Start
  capture in the orientation intended for the stream.

## License

See the repository license.
