# Native guest receive prototype

This isolated application-owned public-SDK prototype is not connected to the
shipping interview UI, source registry, global PCM mixer, Program or ISO recorder.
Constructing it requires an explicit admitted lease. It binds loopback only, has
no STUN/TURN configuration, and never requests a device or reads a credential.
The current transport accepts a synthetic source offer with three distinct
camera/screen/audio MIDs. This is **not** the shipping browser's host-offer protocol.

The immutable [media receipts](../StreamMac/GuestMediaReceipts.swift) carry stable
slot/peer UUIDs, connection generation and negotiation UUID. Video contains an
owned `CVPixelBuffer`, original mapped host PTS, one common mapping generation and
sender-report clock quality. Its source duration is explicitly unknown. Audio
contains owned 48 kHz stereo planar Float32 PCM, actual frame duration and the same
clock identity. Receipts grant no mixer, scene or recording authority. A consumer
must select video due at composition host PTS and schedule PCM at its original PTS;
the common mapping adds 120 ms of playout delay, so displaying future latest pixels
immediately would lead audio. Stop fences delivery and destroys the peer. Different
source-role queues and source identity are never inferred from track order.

Run with a **read-only repaired pinned libdatachannel0.24.0** library/header pair:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
STREAM_GUEST_RTC_INCLUDE=/absolute/include/libdatachannel \
STREAM_GUEST_RTC_LIBRARY=/absolute/libdatachannel.a \
apple/scripts/run_native_guest_receive_harness.zsh
```

The fixture also needs FFmpeg with libx264/libopus and a real libopus reference
decoder (`STREAM_GUEST_LIBOPUS` can specify its library). It generates local canvas
colors/flash and stereo tones, compares independently decoded raw Opus sample
counts/cues, then connects two actual public SDK peers over local DTLS/SRTP. No
external ingest or device is involved. The compile-only deployment target is14.0;
it does not establish runtime compatibility with that OS or with Intel.

The public AudioCodec decoder queries writable PrimeInfo and sets zero trimming
**before** initialization, then uses a variable packet-frame input format and
actual TOC duration. It checks actual appended/produced bytes, packets and frames.
The qualified OS's default Apple Opus decoder omitted120 first CELT samples; a
setter after initialization is a state error. Explicit pre-initialization zero
trimming produced the same sample count and cue as raw libopus. There is no guessed
codec cookie, Ogg pre-skip, PCM padding or first-arrival timestamp compensation.
Missing/dropped input resets the decoder with its sample cursor; it does not carry
old retained state into a new span. An unavailable codec/property or unexpected
packet count produces an error instead of silently changing timing.

Before the pinned depacketizers, RTP validation bounds version, PT/SSRC, CSRC,
extensions, padding and payload length. A private normalized copy strips validated
header extras, preserving clock/source identity; the pinned audio offset bug never
sees untrusted extensions. H264 assembly caps512 packets/2 MiB/250 ms, validates
single/STAP-A/FU-A shapes including consistent fragment NRI/type, accepts complete
IDR recovery after loss, and normalizes private AU sequence numbers only after
checking original wrap-safe continuity. RTCP validation forwards exact sender
reports, while receiving statistics see original validated RTP. PLI requests are
coalesced and rate limited. Compressed decode queues cap video3 frames/2 MiB per
role and audio32 packets/40,800 bytes, with120 ms age rejection and one worker per
role; signaling caps32 items/196,608 bytes on a separate asynchronous queue.

All source clocks map sender NTP onto one host-clock anchor. Fresh report jumps are
bounded against elapsed host time; rolling reports and a first screen report after
13 seconds use the same anchor. No role is independently rebased at first arrival.
The fixture distinguishes malformed datagrams rejected by SRTP before our guard
from validation-only injections into the actual guard, which are compiled only
with `STREAM_GUEST_VALIDATION`.

Remaining qualification: actual Chrome host-offer/guest-answer negotiation with
its application control channel and negotiated H264/Opus formats; consent/approval
and return media; real Program/ISO decoded flash/tone; network loss/jitter/PLC, AEC
and congestion behavior; older supported macOS and repaired Intel linking/runtime.
This prototype supplies no jitter buffer, PLC, AEC or automatic source registration.
Do not claim browser/native interview or roadmap acceptance from loopback receipts.

Public references: [pinned Track API](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.0/include/rtc/track.hpp),
[Apple AudioCodec](https://developer.apple.com/documentation/audiotoolbox/audio-codec-services),
[Apple converter cookie guidance](https://developer.apple.com/library/archive/qa/qa1318/_index.html),
[RTP Opus clock/packet semantics](https://www.rfc-editor.org/rfc/rfc7587.html),
[H264 RTP packetization](https://www.rfc-editor.org/rfc/rfc6184.html).
