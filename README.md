# Stream

**Stream** is an iOS 27+ app that captures the screen and publishes it to RTMP,
RTMPS, SRT, or WHIP endpoints. It uses ScreenCaptureKit for system-managed content
selection and sample delivery; ReplayKit and a broadcast upload extension are not
used.

## Features

- System screen selection through `SCContentSharingPicker`.
- Screen, app-audio, and microphone samples through `SCStream`.
- RTMP/RTMPS publishing with HaishinKit, plus SRT and experimental WHIP support.
- Configurable resolution, bitrate, frame rate, audio mix, and microphone gain.
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

The current Xcode 27 beta does not ship ScreenCaptureKit in the iOS Simulator SDK.
The app provides a simulator stub for previews and non-capture UI, but actual
screen capture must be tested on hardware.

## Build

```bash
git submodule update --init --recursive
xcodegen generate
xcodebuild \
  -project Stream.xcodeproj \
  -scheme Stream \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

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
and composites that frame into the selected corner before encoding. Devices that
cannot keep a camera session active during multitasking fall back to screen-only.

## Notes

- ScreenCaptureKit is device-only in the current Xcode 27 beta SDK.
- Local backup remains disabled because it requires a second video encoder.
- WHIP should be validated on hardware because its WebRTC stack has a larger
  memory footprint than RTMP or SRT.
- The output resolution locks to the first captured frame's aspect ratio. Start
  capture in the orientation intended for the stream.

## License

See the repository license.
