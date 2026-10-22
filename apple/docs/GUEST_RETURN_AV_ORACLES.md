# Guest return A/V timing oracles

The raw-track recording and independently rendered measurements have different
clock and consumer boundaries. A raw-track recording must not be labeled a
recording of normal HTML media-element playout.

## Exact Chrome boundary, 2026-10-21

The tested Chrome is 155.0.8059.85. Its
[HTMLMediaElementCapture implementation](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/modules/mediacapturefromelement/html_media_element_capture.cc)
returns a stream using the incoming descriptor when the element is playing a
MediaStream. It does not use its rendered-element capturer in that case. The
actual probe independently observes the same `audio-return` and `video-return`
track identities before and after `captureStream()`.

The existing default fixture therefore records decoded raw tracks through
MediaRecorder. Its 100 ms limit remains unchanged. The independent rVFC video /
raw-track AudioWorklet estimate also retains its 100 ms limit, but its audio
consumer is a separate AudioContext, not the element's normal output path.

The retained failed recording `decoded-return-1792616136258.webm` has first white
video PTS 1.228 s and first tone PTS 1.3331041667 s: **−105.104 ms**, beyond the
unchanged limit. Reconstructing the audio cue from contiguous sample count gives
−103.104 ms, so the failure cannot be dismissed as a simple packet timestamp
rounding error. The simultaneous independent estimate was −90.527 ms and the
native source cue difference was +11.477 ms. These observations do not establish
the normal physical/HTML-element playout difference or identify a sender bug.

## Optional element-audio provider probe

`--video-element-audio-probe=program` uses real rVFC callbacks to paint an owned
canvas and tries the element's audio through createMediaElementSource. This is
an instrumented alternative audio graph, not untouched output. It separately
observes the original raw audio track as a positive PCM control. It never
replaces the default raw-track gate.

On the tested browser, the actual remote element provider produced 100,352
frames with peak 0 and no tone cue. The simultaneous raw-track control produced
100,352 frames, peak 0.4202 and a tone cue. The native source delta was 14.932 ms;
the largest observed callback / expected-display difference was 16.7 ms. The
probe retained its WebM artifact and exited **77 / UNQUALIFIED**, after retiring
the guest and native process. A silent provider can never count as an A/V pass.

This matches the exact browser implementation:
[WebMediaPlayerMS](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/public/web/modules/mediastream/web_media_player_ms.h)
does not override
[GetAudioSourceProvider](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/public/platform/web_media_player.h),
whose default returns null. The
[HTMLMediaElement provider wrapper](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/core/html/media/html_media_element.cc)
outputs silence without that provider. Successful local-file element/WebAudio
calibration cannot be transferred to a remote MediaStream source.

Use the normal native return-video runner with this explicit opt-in argument.
It uses only owned local Worker/TURN, synthetic source media and an isolated
Chrome profile. It requests no microphone, camera or screen permission. This
probe does not qualify speakers, physical/browser AEC, untouched element output,
mobile playback or deployed-network timing.

## Actual HTML player clock reset and repair

The shipping guest previously reassigned the same return `MediaStream` to
`srcObject` whenever the host changed video visibility. Exact Chrome155
[`SetSrcObjectVariant`](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/third_party/blink/renderer/core/html/media/html_media_element.cc)
invokes the load algorithm even when the descriptor is unchanged. In an actual
native/owned-TURN/Chrome run, video attachment changed `currentTime` from
3.289256 seconds to 0.035524 seconds, with a second `loadstart` and `emptied`
event despite the identical stream object.

The guest now changes track membership idempotently and attaches `srcObject`
only when its stream identity changes. The production-path regression preserves
the existing player's clock from 3.297371 through 10.882880 seconds across video
On/Off, explicit restart, Secondary selection/removal/restoration, Clean selection,
and the actual mixer mute/restore path. It observes one load and no empty event
during those transitions. Rejoining retires that stream and correctly loads a
new full-lease stream; existing decoded pixels, own-audio exclusion, private
message routing, mute/restore and terminal cleanup checks remain in place.

This verifies a real HTML player lifecycle/clock fix. It does not measure final
rendered PCM or explain the retained 105.104 ms raw-track failure, and is not a
replacement A/V timing oracle. The original 100 ms raw-track and independent
consumer bounds remain unchanged. Addressed talkback playback and physical or
browser AEC still need their actual consumer/feedback qualification.

## Read-only audio producer attribution and current capture gate

`apple/scripts/owned_chrome_audio_process_probe.swift` reads public Core Audio
process properties and ScreenCaptureKit shareable metadata for one caller-owned
Chrome parent. It verifies process ancestry/start identity and reports only that
owned process family. It creates no tap or aggregate device, starts no capture,
requests no permission, and changes no device or output selection. An unrelated
non-Chrome PID is rejected with exit77.

The normal unmuted Chrome file-player control had advancing media time and an
actual HAL process marked as running output. That process was a verified direct
child of the owned browser; the shareable-application list contained the browser
parent only. This narrows attribution investigation but does not establish that
child ownership explains the previous silent SCK result or that SCK cannot group
an app family.

The current session is locked. Existing screen-capture preflight is true but
SCK reports zero shareable displays. The exact-app output calibration therefore
retains exit77/UNQUALIFIED before obtaining its selected-Chrome positive PCM
control. No zero signal or metadata counter counts as a successful calibration.
No session was unlocked and no permission was requested. A Core Audio process
tap is a separate route: Apple's [tap capture documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
states that starting recording can present an audio-recording permission prompt.
No documented public preflight for that separate grant was established here,
so tap recording was not started under the no-new-consent constraint.

Build the read-only helper:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  apple/scripts/owned_chrome_audio_process_probe.swift -o /absolute/owned/probe
```

Optionally set `STREAM_CHROME_AUDIO_PROCESS_PROBE` to that executable when running
`chrome-output-oracle-calibration.mjs`; the diagnostic does not bypass any
existing positive/negative PCM or 0/±150 ms calibration gate.
