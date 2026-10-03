# Native guest receive prototype

This isolated application-owned public-SDK prototype is not connected to the
shipping interview UI, source registry, global PCM mixer, Program or ISO recorder.
Constructing it requires an explicit admitted lease. It binds loopback only, has
no STUN/TURN configuration, and never requests a device or reads a credential.
The transport supports two mutually exclusive modes: a synthetic source-offer
fixture, and a native host offer answered by the shipping browser guest. The native
host offers three distinct camera/screen/audio MIDs plus the reliable approval
channel. It offers only constrained-baseline H264 mode1 primary media (no RTX) and
Opus, then validates the exact negotiated codecs, direction and primary SSRCs.

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

Controlled native and Chrome fixtures pass on macOS27.0.1 arm64, Xcode26.6/SDK26.5,
Chrome154.0.8037.95 and pinned SDK0.24.0. They decode actual320x180 camera/screen
pixels and stereo48k PCM through ICE/DTLS/SRTP, including received MID extensions,
approval/default deny/reset, screen-only stop, fresh generation replacement and
no receipts after stopped. The native fixture independently checks real libopus
counts/cues, mono/SILK/hybrid and2.5–60 ms packets, long-call/late-screen clocks,
bounded malformed assembly and blocked-callback revocation. These are local
synthetic media and loopback signaling fixtures, not a deployed service.

Remaining qualification: shipping admission/controller binding and return media;
real Program/ISO decoded flash/tone; network loss/jitter/PLC, AEC and congestion
behavior; TURN, physical devices, older supported macOS and repaired Intel
linking/runtime.
This prototype supplies no jitter buffer, PLC, AEC or automatic source registration.
Do not claim shipping interview or roadmap acceptance from loopback receipts.

For the actual Chrome/native fixture, build the bounded JSON-lines host CLI with
the same public library/include environment and
`apple/scripts/build_native_guest_host_cli.zsh`. Set `NATIVE_GUEST_HOST` to the
printed binary path when running the independently owned browser fixture. The CLI
never acquires a device or writes source/scene state. It caps commands and output
queues, writes stdout with a one-second nonblocking deadline, and fences captured
generation/negotiation on every command. An ordinary Leave produces a control-state
closure receipt; command failures remain explicit errors. Screen approval starts
false, uses only `stream-interview-control-v1`, and limits messages to1024 bytes and
outgoing backlog to8192 bytes. Revocation fences prior callbacks before returning;
caller receipt locks must be released around that gate. Closing the control channel
revokes screen permission and preserves camera/audio. Sender-report acceptance
requests bounded IDR recovery when the first keyframe preceded clock readiness.
Negotiated MID extensions pass the same bounded normalization as the synthetic
decorated packets; actual received extension counts appear in CLI receipts.
Unsupported negotiation/codec/property states fail explicitly. The used fat
archive's upstream Intel slice lacks the required RTC implementation; its public
C++ symbols and link must be verified after the existing pinned source repair.

Public references: [pinned Track API](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.0/include/rtc/track.hpp),
[Apple AudioCodec](https://developer.apple.com/documentation/audiotoolbox/audio-codec-services),
[Apple converter cookie guidance](https://developer.apple.com/library/archive/qa/qa1318/_index.html),
[RTP Opus clock/packet semantics](https://www.rfc-editor.org/rfc/rfc7587.html),
[H264 RTP packetization](https://www.rfc-editor.org/rfc/rfc6184.html).
