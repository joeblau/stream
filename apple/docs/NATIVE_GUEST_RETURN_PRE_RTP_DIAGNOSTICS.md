# Bounded pre-RTP diagnostic evidence

This diagnostic change supports the still-open guest return task #127. It fixes
an evidence gap in the owned, synthetic, all-Chromium null-output discriminator;
it changes no native SDK, production signaling, receiver clock or media policy.
No new browser/RTC attempt was run to validate this change.

The retained [wave11 receipt](NATIVE_GUEST_RETURN_NULL_OUTPUT_WAVE11_2026-10-22.json)
remains UNQUALIFIED/77: both peers had stable signaling, two local and two remote
SDP candidates, but ICE/connection stayed `new`. Sender Opus reported zero sent
packets/bytes; receiver inbound RTP had no row. Both null contexts ran and source
PCM was positive, while receiver PCM was zero. The twelve-second measurement was
never reached. This differs from the older native 931-packet receive failure.
Wave11's trace callback counts remain retained lower bounds under its byte cap.

The earlier failure snapshot retained only transports with a selected pair. An
empty transport array therefore could not distinguish an absent transport from
an existing transport with no selected pair. Candidate delivery was also
unobserved after an unawaited trickle call. Existing evidence cannot establish
pair formation, candidate-call completion, DTLS progress or a network cause.

## Fixed diagnostic contract

`owned-loopback-failure-snapshot.mjs` now retains every inspected transport,
including unselected transports, with fixed ICE/DTLS state and role enums,
optional aggregate counters, and separate booleans for a selected-pair reference
and its resolution to an actual candidate-pair row. Missing numeric fields stay
absent; an explicit zero stays zero. Missing/unsupported enums become `unknown`.

It retains at most eight candidate-pair rows with optional nomination, fixed
check/consent/packet/byte/RTT counters and candidate type/protocol classifications.
Local and remote candidate aggregates contain only type/protocol counts.
Description evidence contains fixed type enums for local/remote, current and
pending descriptions. SDP contributes candidate counts only.

There are at most two peers, two transport rows per peer and 256 enumerated stats
rows per peer. Bounded reference lookups classify retained pairs; their IDs never
leave the helper. Row and per-array truncation flags are explicit. When the
256-row inspection cap is hit, observed counts are lower bounds; absence or
`referencedAsSelected: false` cannot rule out evidence outside that window.
The existing failure-only 500 ms stats budget is unchanged. Late stats cannot
modify an already returned receipt.

`owned-loopback-signal-journal.mjs` observes the existing API calls synchronously
and returns each original native promise. The original queued-candidate awaits,
direct trickle `.catch` calls, signaling order and end-of-candidates behavior are
preserved. An end event is observed without newly forwarding a null candidate.
No drain, retry or additional signaling wait is introduced.

Each attempt-local generation has an active lease, fixed side/operation counters
and at most 64 ordered events. Invocation/start/completion/rejection events link
by local sequence number, retain the invocation phase, and classify the settlement
phase. Settlements from a retired/replaced generation increment a separate stale
counter without updating the current generation's operations or events. Event
retention drops are counted. The failure helper independently allowlists and
copies at most ten counter rows and 64 events before awaiting stats. No argument,
candidate/description object, identifier, address, port, fingerprint, credential,
error message or media sample is retained.

The unchanged acceptance bounds are 60 s overall, 16 s phase progress, 10 s
connection initialization and 12 s positive measurement. The original PCM/RTP
positive assertions and UNQUALIFIED handling are unchanged. Observability cannot
rescue an unsuccessful attempt or qualify #127.

## Owned non-media validation

Eighteen Node tests cover privacy/bounds, absent versus unselected transport,
failed checks, connected ICE with pending DTLS, unresolved selected references,
optional counters, explicit truncation, serialized helper independence, frozen
pre-cleanup evidence, original-promise identity, rejection propagation, invocation
versus settlement phase, generation retirement and stale settlement fences. The
actual serialized diagnostic page is executed with controlled API objects:
each queued candidate promise is held to prove its await, while both direct
trickle promises remain held through the failure snapshot and cleanup. Later
settlement cannot mutate that receipt. These are protocol-observer tests; they
establish no ICE, DTLS, RTP, browser media or native interoperability result.

Run with the repository-supported Node >=24.15 <25:

```sh
node --test workers/interviews/test/browser/owned-loopback-failure-snapshot-client.mjs \
  workers/interviews/test/browser/owned-loopback-signal-journal-client.mjs \
  workers/interviews/test/browser/owned-loopback-lifecycle-client.mjs
```

The new `*-client.mjs` test is included by the existing `test:client` CI glob.
No dependency, build, browser, permission, device, network or output is required.

## Primary API references

Field names and enum meanings follow the W3C [WebRTC statistics specification](https://www.w3.org/TR/webrtc-stats/):
`RTCTransportStats`, `RTCIceCandidatePairStats` and `RTCIceCandidateStats`.
Promise-returning description/candidate operations and current/pending description
properties follow the W3C [WebRTC specification](https://www.w3.org/TR/webrtc/).
Names and optionality were also checked against the repository's TypeScript 5.9.3
`lib.dom.d.ts` declarations for `RTCTransportStats` and
`RTCIceCandidatePairStats`; no unsupported ICE object role or transceiver stopped
property is assumed.

The next independently scheduled discriminator, if authorized, must bind this
new journal's source hash as well as the launcher/snapshot/lifecycle/process
helpers. The retained wave11 artifacts and earlier failed/interrupted receipts
remain immutable; this change does not supply their missing observations.

## Measured wave12: completed calls without observed candidate pairs

The one separately authorized attempt at published
`e8033037ee0a5bd51ed9b7b803ea8c34347f265b` ended UNQUALIFIED/77 after 11.398 s
at the unchanged connection deadline. Its [bounded receipt](NATIVE_GUEST_RETURN_NULL_OUTPUT_WAVE12_2026-10-22.json)
binds all eight source files, Node/Chrome/ws bytes, one invocation intent,
preflight and process/drain proofs. No retry followed; the twelve-second
measurement never began.

All ten observed API calls completed: offer, answer, four description calls and
four candidate calls. All 36 journal events remained retained in active
generation 1, with zero rejections, in-flight calls, stale settlements or drops.
Current offer/answer descriptions were present and pending descriptions absent.
Each peer exposed one unselected transport, ICE/DTLS both `new`, zero selected-pair
changes and zero transport packets/bytes. Complete 11/8-row stats snapshots
exposed zero candidate-pair and remote-candidate rows, versus four local host
candidate rows per peer (two UDP/two TCP). Fulfilled candidate API promises do
not establish internal resolution/materialization; no network or mDNS cause is
assigned by those absent rows.

Both null contexts ran; generated sender PCM was positive across 483328 frames,
while receiver PCM was zero across 481280 frames. Sender Opus explicitly reported
zero packets/bytes; receiver inbound RTP had no row. The retained trace has
24998 events and an observed byte counter 36224 bytes over the 8 MiB cap, so its
callback counts remain lower bounds despite protocol trace completion. Cleanup
and a subsequent read-only check confirmed the owned process group and profile
were gone. This all-Chromium result does not reproduce or explain the older
native 931-packet symptom, qualify a receive-clock fix or close #127. The next
source boundary is fulfilled candidate calls versus exposed remote candidates
and pair construction. All older receipts remain unchanged.
