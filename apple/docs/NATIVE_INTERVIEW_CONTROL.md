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
The standalone session has no default receiver factory. The runtime manager
binds the public-SDK factory without a loopback ICE fallback. Missing TURN stops
preparation before native host allocation.

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

## Runtime Guests controls

`StudioRuntime` owns `NativeInterviewManager`. The Guests pane accepts an
explicit HTTPS service URL/origin and a temporary SecureField operator
credential. Nothing creates or rejoins a room at launch. Copying the invite is
an explicit sharing action; neither command capabilities nor local IPC results
contain an invite, credential, TURN configuration or SDP.

The UI, palette, shortcuts and paired controller adapters use the same typed
dispatcher commands for admission, Backstage, On Air, private Monitor, screen
approval/revocation, media reconnect, removal, lock, host disconnect/rejoin and
ending. Guest command IDs contain the current invite UUID. Camera and screen
have separate persistent source IDs and independent Preview framing; adding a
source to Preview does not Take it or grant Program permission.

On Air combines a deliberate full-lease local intent, an actual new service
membership receipt, and matching media readiness. An onair roster alone cannot
grant Program. Repeating an already acknowledged unchanged On Air intent keeps
its valid receipt even when a service treats the repeated command as a no-op.
Backstage synchronously revokes Program while retaining only an explicitly
enabled private Monitor route. Screen revocation clears cached screen frames
synchronously; actual adapter control-channel closure revokes screen without
retiring healthy camera/audio. Remove, disconnect, ending, recovery and runtime
replacement close old full-lease authority before awaiting service work.

The runtime allocator remains monotonic across rooms. Captured preparation
occupancy remains bounded across cancellation and replaced sessions. Retiring
the manager's credential source synchronously disables future reads; client
shutdown also drops its provider closure. Copies already passed to an in-flight
transport may live until that transport returns or cancels. This is credential
lifetime control, not a promise of memory zeroization.

Hosting-view detach/reopen retains the same runtime-owned manager and peer;
profile replacement and the actual Quit hook retire it. This does not claim
that reopening a terminated app preserves an in-memory room: Apple's single
[`Window`](https://developer.apple.com/documentation/swiftui/window) normally
terminates its app when its sole window closes.

## Reproduce manager, routing and owned window evidence

After the locked Node/npm installation above, run on a logged-in macOS desktop:

```sh
zsh apple/scripts/run_native_interview_manager_harness.zsh
```

`INTERVIEW_MANAGER_BUILD_PATH` selects an owned derived directory and
`STREAM_VENDOR_ROOT` may select an external initialized vendor checkout. The
runner builds actual desktop sources, with existing nil/no-network validation
credential boundaries, a UUID defaults suite/machine folder, and refusal at
the capture-start boundary. The default recorder directory is also private.
It extracts the actual shipping App root and hosts the actual MainWindow.
It does not request devices, pair an operator client, deploy, or start output.

Every room/admission/stage/roster/rejoin/revoke/end in this fixture uses actual
URLSession against the owned local Worker. Only relay provisioning and the
media host are explicit controlled boundaries. The host uses the shipping
controller-issued sink and actual receiver event bridge. Actual Program/Monitor
mixer taps measure independently paced synthetic PCM: silence before a held
real stage receipt, the original tone after receipt, unchanged permission on
repeated On Air, and private Monitor-only Backstage. Tests also exercise screen
grant/control closure/revocation, distinct camera/screen source framing,
two-room high-water, removal during a held real mixer actor registration, and
actual SwiftUI view detach/profile replacement/old-view/ Quit ownership.

This qualifies control and native routing authority. It does not qualify the
controlled host's SDP as WebRTC, RTP decoding, positive relay-only connectivity,
Program/ISO encoded output, camera permission/device behavior or deployed TURN.
The production receiver must independently qualify its selected native relay
pair and fails closed before readiness/media if that policy is not satisfied.

| Issue criteria | Evidence from this change | Remaining qualification/work |
| --- | --- | --- |
| #125 native host lifecycle | Actual local service, single-peer admission/rejoin/end, bound factory/sink and generation fences | Combined manager entry with real media, studio return media, mobile/restricted networks and measured larger capacity; separate actual local receiver relay proof is in NATIVE_INTERVIEW_RECEIVER.md |
| #128 studio controls | Native lobby, Backstage/On Air, private Monitor, screen permission, removal/reconnect/lock, separate source framing and shared commands | Rename/mute/solo end-to-end workflow, remaining scene actions, private talkback/messages, operator/manual UI qualification |
| #130 guest screen | Independent registered camera/screen sources and host approval/revoke/control-close routing gates | Combined manager entry and encoded outputs, permission-denied and unsupported-browser behavior across the full native workflow; separate real adapter camera/screen approval and independent stop pass the local relay fixture |
