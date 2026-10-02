# Explicit remote event recovery review

Recovery persists bounded public provider/channel/event IDs, the local publisher
session UUID and its capture time. The binding comes from the output that
actually started. Later destination edits cannot substitute another event. A
local stop or transport failure retains the most recent binding; it does not
establish a remote end. The recent inventory has at most ten outputs, preserving
active sessions before evicting older stopped entries. It is not an exhaustive
remote-event history.

Opening a journal never reads a provider, starts a publisher, ends an event or
replays a command. Saved states are unknown after restart. Legacy v1 journals
remain readable, but missing owner/session metadata requires external review.
Verify Remote State explicitly reads current authorized YouTube channels
(`channels.list`, `mine=true`), then the exact broadcast ID. Both are uncached
GETs. Only a current owned channel, exact owner/event match, unchanged account
authorization and unchanged project/profile runtime can produce a receipt.
Permission errors, unavailable APIs, absent/foreign events, quota limits,
timeouts, future or stale receipts remain unknown.

Fresh `complete` or `revoked` states are ended. Exact `live` is a reconnect review
candidate: it does not validate the current ingest configuration and does not
authorize an automatic local start. `created`, `ready`, `testing`, transitional
states and unsupported providers remain unknown. Receipts expire after sixty
seconds and never refresh automatically. Two request slots bound work, including
requests which ignore cancellation; context replacement and shutdown fence all
late responses.

Official API semantics:

- [Broadcast lifecycle states](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts#status.lifeCycleStatus)
- [Read broadcasts and required authorization](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/list)
- [Read currently authorized channels](https://developers.google.com/youtube/v3/docs/channels/list)
- [Live transitions require active bound ingestion](https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/transition)

## Local software evidence

`scripts/run_recovery_event_review_harness.zsh` exercises the actual output
controller's immutable start snapshot, local stop and replacement session;
atomic disk checkpoint and new coordinator restart; explicit fresh API fixture
reads; ended/live/unknown classifications; owner, account and profile fences;
receipt expiry; timeout/late-response isolation and a two-job cancellation bound.
Fixtures inject HTTP and publishers and issue no network, Keychain, TCC or real
provider mutation. `RecoveryEventReviewTests` cover the public request contract,
legacy metadata decoding, identifier validation and lifecycle/timestamp rules.

These checks qualify the implemented software boundaries. A physical abrupt
process/OS interruption, damaged media repair, accessibility and a real authorized
provider's restart workflow still require separate acceptance evidence. Finalized
copies of already-readable generated recordings are not abrupt-kill repair proof.
