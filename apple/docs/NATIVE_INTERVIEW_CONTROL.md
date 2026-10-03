# Native interview service control foundation

`NativeInterviewServiceClient` and `NativeInterviewSession` implement the existing
`workers/interviews` host protocol using public Foundation APIs on macOS 14 or
later. This foundation has an explicit limit of **one native admitted guest**.
The backend's capacity of ten is separate from native capacity qualification.

The client accepts an explicit HTTPS service configuration and an injected
operator credential provider. Room creation, invite creation and operator end
are single requests. Connection loss does not reconnect, replay a mutation,
readmit a guest, or restore screen/Program permission. Host capabilities, invite
fragments, SDP and TURN credentials remain private memory; none are Codable,
scene settings, defaults, published snapshots, command results or diagnostic
messages. Sharing deliberately returns a private invite whose capability is in
the URL fragment. The operator credential has no default reader.

The native session exposes service lobby, admission, membership, lock, status,
revocation, explicit rejoin, and acknowledged ending. Service `onair` and
`program` flags do not register a source or grant local Program/audio/recording
authority. A runtime manager must capture deliberate local intent by the full
`NativeInterviewPeerLease`, require the matching acknowledged service state,
and compare `readyPeerLease(for:)` immediately before granting routing. Retired,
waiting, timed-out and replaced contexts have no ready lease.

The injected host factory receives both Worker generations and the exact native
`GuestReceiveLease`. Supply the runtime's monotonic `nextGeneration` allocator
when constructing sessions; ending a room must not reset a retained controller's
admission high-water. The standalone default counter is for isolated sessions.
There is no default receiver factory or loopback ICE fallback. Missing TURN
stops preparation before native host allocation.

Every incoming server delivery is acknowledged before native work. A bounded
sender prioritizes ACKs and spaces normal messages by at least 20 ms, respecting
both server rate limits and the delivery-credit window. Incoming signals require
the current host generation, guest generation and negotiation. Obsolete inner
negotiations are discarded before interpreting their SDP/ICE. A malformed
current peer payload retires that peer while host controls stay connected.
Camera, screen and audio have distinct negotiated MIDs. Screen approval starts
false; control-channel loss removes screen permission without retiring healthy
camera/audio authority.

HTTP requests have a bounded whole-transfer deadline, a 16 KiB response limit,
ephemeral URLSession storage, no redirect following and no credential store.
WebSocket receives are limited to 64 KiB. Preparation and negotiation deadlines
retire current authority. There are at most four occupied client requests and
two occupied media preparations, including canceled/noncooperative work until
it actually returns. Queues are bounded by both item count and bytes; candidate
failure is reported independently from answer processing.

Relay credentials are cached only in memory and refreshed before expiry. An
existing host still retires at the expiry of the credentials used to construct
it; refreshing the cache does not rewrite an active SDK peer's ICE credentials.
A deliberate fresh media restart is required. Long-call credential renewal,
deployed TURN connectivity, operator devices, provider credentials, greater
native capacity and a complete production Guests workflow need their own proof.

## Reproduce the control fixture

Install the locked Worker development dependencies with Node `>=24.15 <25` and
npm 12, then run on macOS with Xcode command-line tools selected:

```sh
cd workers/interviews
npm ci
cd ../..
zsh apple/scripts/run_native_interview_control_harness.zsh
```

`STREAM_INTERVIEW_NODE` may name a Node 24 executable. The runner starts the
actual pinned local Wrangler/workerd service on owned loopback ports. It creates
a fresh synthetic operator credential in a mode-0600 config under an ignored,
mode-0700 UUID build directory. Worker persistence and build cache stay inside
that directory. After stopping the child, the runner removes the credentials,
Worker state, generated config and cache. Retained logs contain bounded progress
metadata, never capabilities or SDP. It reads no operator Keychain/defaults,
deploys nothing, and requests no capture devices.

The fixture proves actual URLSession HTTP/WebSocket create, lobby, admission,
service state, a 48-command ACK-credit burst, host/guest rejoin, revocation,
acknowledged end and capability retirement. The actual unconfigured TURN response
blocks native factory allocation. Additional tests use the same real local
service while injecting only relay provisioning and a clearly synthetic media
boundary: exact negotiation/generation, screen-control loss, waiting privacy,
callback overflow, two occupied held preparations, timeout/late completion,
two-room runtime generation allocation and held relay replies across reconnect.
Controlled HTTP transports prove cancellation occupancy and no POST replay.
These boundary tests do not prove decoding, Program/ISO media or TURN traversal.

Public API references: Apple's
[WebSocket maximum message size](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask/maximummessagesize)
and [redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).
