# Chrome to native host fixture

This optional fixture serves the shipping guest page against a loopback signaling double and an app-owned native receiver CLI. Chrome creates the guest answer and sends actual H264/Opus RTP. Assertions use native decoded pixel and PCM receipts, including distinct camera/screen tracks, explicit screen approval, independent screen stop, and fresh negotiation cleanup after reconnect.

Build the macOS receiver CLI using a read-only repaired pinned libdatachannel 0.24.0 header/library pair. From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
STREAM_GUEST_RTC_INCLUDE=/absolute/include/libdatachannel \
STREAM_GUEST_RTC_LIBRARY=/absolute/libdatachannel.a \
apple/scripts/build_native_guest_host_cli.zsh
```

Install the pinned interview development dependencies with Node 24.15:

```sh
cd workers/interviews
npm ci --ignore-scripts
NATIVE_GUEST_HOST=/absolute/path/to/guest-host-cli node test/browser/native-host-browser.mjs
```

The native receiver prototype's separate build runner produces `apple/build/native-guest-receive/guest-host-cli`. Set `CHROME_BIN` to a Chrome/Chromium executable on systems where Chrome is not at the default macOS location. `CHROME_NO_SANDBOX=1` is available for CI containers that require it. The fixture uses a temporary isolated Chrome profile and cleans up its processes, sockets and generated tracks on completion.

Locally qualified on macOS 27.0.1 ARM64 with Xcode 26.6, Node 24.15 and Chrome 154.0.8037.95. The native compile target of macOS 14 does not qualify runtime behavior on that version or on Intel.

Capture APIs are replaced with animated 320×180 red/blue canvas streams and a stereo AudioContext tone. No camera, microphone, screen picker, operator profile, credentials, STUN or TURN service is accessed. The peer connection, browser codecs, DTLS/SRTP transport and native H264/Opus decoders remain real. The Worker is covered by the separate workerd tests; this signaling double does not qualify its deployment or authorization behavior. Passing this fixture does not establish shipping engine/Program routing, mix-minus, echo cancellation, physical-device support, mobile browsers, restricted networks, or production interview service support.

## Native CLI protocol

Use JSON-lines on stdin/stdout. Each receipt and command belongs to an explicit positive integer `generation` and UUID `negotiation`. Lines are bounded; SDP and ICE dictionaries are transported in memory and omitted from test logs.

Commands:

- `start`: `media` contains distinct safe `audio`, `camera`, `screen` MIDs. The native host creates three receive transceivers and the reliable `stream-interview-control-v1` data channel.
- `answer`: `description` is the browser's actual `{type:"answer",sdp}`.
- `candidate`: `candidate` is the browser's actual `{candidate,sdpMid,sdpMLineIndex,...}` dictionary.
- `approval`: `approved` is an explicit boolean screen grant for this negotiation.
- `stop`: seals output and destroys this native lease.

Receipts:

- `offer`: `description` is `{type:"offer",sdp}` and `media` is the semantic MID map.
- `candidate`: `candidate` contains `{candidate,sdpMid}`.
- `ready`: the peer and approval data channel are open.
- `control`: `message` contains the guest's `{type:"screen-state",negotiation,sharing}`.
- `control-state`: `state:"closed"` acknowledges approval-channel teardown. This fixture permits closure only after explicit guest Leave; an earlier closure fails it.
- `decoded`: `role`, host-clock `pts`, stable UUID `mappingGeneration`, `clockQuality:"senderReportAligned"`, and monotonic `headerExtensions` received-packet count. This fixture requires actual negotiated MID header extensions on camera, screen, and audio RTP. Video adds `width`, `height`, `centerRGB`; audio adds `frames`, `channels:2`, `sampleRate:48000`, `rms:[left,right]`, and actual sample `duration`.
- `stopped`: gate/destroy finished, with no later media or signaling receipts.
- `error`: bounded metadata describing a failed protocol/media operation.

The initial approval is false. Negotiation replacement must clear it. This fixture deliberately preserves the existing host-offer/guest-answer and negotiation-tagged approval contracts; it does not introduce guest-originated offers.
