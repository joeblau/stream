# Native interview to Program and associated ISO

The controlled fixture runs the shipping `NativeInterviewManager`, its default
`NativeInterviewReceiverFactory`, the controller-issued registered sink, real
public-SDK H264/Opus reception, and the shipping compositor and mixer. It records
actual Program and controller-resolved guest-camera ISO files with their common
recording timeline, then decodes both files with `AVAssetReader`.

Control uses the real local Worker and URLSession HTTP/WebSocket client. Media
uses owned pinned Coturn and requires both endpoints' actual selected local
candidate to be UDP relay. The shipping guest page answers the native offer and
sends generated camera, screen and stereo AudioContext media. Only local TURN
provisioning is overridden; this does not qualify the deployed TURN broker.

The full-source generated tool refuses the automatic local microphone start,
uses the common credential-isolated fixture boundaries, and makes only blank
and explicitly registered guest source demand. It keeps the production factory,
receiver, renderer, dispatcher, routing gates, mixer and writers. Generated
read-only observers retain bounded counters and original media timestamps after
the actual sink accepts them; they neither admit media nor change timestamps.
Temporary credentials/configuration, Worker state and Chrome profile are owned,
private and removed after bounded child-process cleanup. Encoded synthetic clips
and numeric proof receipts remain in the selected build artifact directory.

The fixture verifies:

- Real service admission begins backstage. Generated audible RTP continues,
  while actual Program pixels and both Program/pre-fader ISO PCM stay black and
  silent. OnAir requires the actual stage receipt before controller routing.
- H264 camera pixels and stereo Opus PCM traverse the default native manager
  path. Ordinary sparse Chrome audio sender reports keep decoding past three
  seconds; their receipt horizon remains bounded as described in
  [the receiver boundary](NATIVE_INTERVIEW_RECEIVER.md).
- A known source flash/tone survives compositor, mixer and both encoded files.
  Original accepted source PTS, live cue PTS and recorded PTS are inspected.
  Live and file AV differences stay below 50ms, audio/video endpoints below
  40ms, and Program/ISO cues within one rational 48kHz sample.
- Every audible pre-writer Program/ISO PCM window has identical original PTS
  and values. Both decoded files have the exact same audio origin, sample count
  and every Float32 bit pattern. Their tails are black and silent.
- Screen starts denied, real control-channel approval enables its separate MID
  and compositor inset, and independent stop/revocation preserves camera/audio.
  Historical ISO flash queries retain their due frames without consuming the
  Program lookup or choosing future pixels.
- Actual disconnect/rejoin preserves the stable source slot and allocates a
  fresh full lease/negotiation. It resets Program/screen intent. A captured first
  ISO renderer rejects replacement-generation pixels, while a fresh second
  recording receives the new camera. Actual room end stops browser capture and
  native ingress; terminal cleanup emits no later receipt.

Install the pinned interview development dependencies using Node 24.15 or newer
within major version 24. Build owned Coturn using the existing pinned helper in
[the receiver instructions](NATIVE_INTERVIEW_RECEIVER.md), then run:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
STREAM_VENDOR_ROOT=/absolute/clean/external/Vendor \
STREAM_GUEST_RTC_INCLUDE=/absolute/pinned-libdatachannel-source/include \
STREAM_INTERVIEW_TURN_SERVER=/absolute/owned/turnserver \
STREAM_INTERVIEW_NODE=/absolute/node24/bin/node \
STREAM_INTERVIEW_PROGRAM_BUILD_PATH=/absolute/owned/derived-data \
CHROME_BIN='/absolute/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' \
apple/scripts/run_native_interview_program_iso_harness.zsh
```

The runner resolves and verifies the required compiled relay-policy marker.
`STREAM_INTERVIEW_REFERENCE_ARTIFACTS` can name a read-only qualified
`SourcePackages/artifacts/haishinkit.swift` tree; the runner copies it into its
own derived directory and still verifies the patch/source/archive receipt.
The Chrome child uses the fixture-only mock-Keychain switch with its sandbox
and ten-second CDP deadline preserved.

Locally qualified with macOS 27.0.1 ARM64, Xcode 26.6/SDK 26.5, Node 24.15.0,
Chrome for Testing 154.0.8037.92 and pinned Coturn 4.18.0. Two complete runs after
the actual history correction each passed two recorded/rejoined segments. The
final run recorded 155,144 and 151,941 PCM frames per file, respectively; all
310,288 and 303,882 decoded Float32 values matched exact bits. Both segments had
zero missing ISO flash-history queries and zero rational cue difference.

This is controlled local software qualification. It does not qualify Intel or
macOS 14 runtime, physical camera/microphone/screen capture, deployed service or
TURN provisioning, Internet/mobile/restricted networks, larger guest capacity,
return media/mix-minus/AEC, or signed installation. Production entitlements,
helpers and vendor sources are unchanged.
