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
The account boundary fences both this workspace's authorization-intent epoch
and the vault's credential generation before and after reads. A captured old
credential generation is rejected at vault actor entry. A 401 ends the explicit
review without replaying its GET or performing a forced OAuth refresh; the
operator must repair authorization and verify again.
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

The injected native fixtures and combined app build passed on Mac15,8, macOS
27.0.1 (26A434), Xcode 27.2 (27B5019j). The existing account fixture also passed,
including its default safe GET retry path. This is named-machine software
evidence, not qualification of every supported OS or provider account.

`scripts/run_recovery_event_review_harness.zsh` exercises the actual output
controller's immutable start snapshot, local stop and replacement session;
atomic disk checkpoint and new coordinator restart; explicit fresh API fixture
reads; ended/live/unknown classifications; owner, account and profile fences;
receipt expiry; timeout/late-response isolation and a two-job cancellation bound.
Fixtures inject HTTP and publishers and issue no network, Keychain, TCC or real
provider mutation. `RecoveryEventReviewTests` cover the public request contract,
legacy metadata decoding, identifier validation and lifecycle/timestamp rules.

`scripts/run_recovery_accounts_harness.zsh` additionally runs the shipping
account session, injected machine credential vault and review binding together.
It proves that read-only scope is sufficient, missing scope blocks requests,
POST/body/token-resource requests never cross the boundary, 401 never retries,
and account replacement/forget/retirement invalidates late receipts. It uses an
in-memory credential store and HTTP fixtures, not production Keychain secrets.

These checks qualify the implemented software boundaries. The separate
[abrupt recording fixture](ABRUPT_RECORDING_RECOVERY.md) launches and SIGKILLs
only an owned recorder process, then runs shipping startup review and actual
fragment decoding/finalized-copy export while preserving the originals. Its
default H.264/MP4 scope differs from OS/power interruption, physical-volume
damage, general accessibility and an authorized provider's external restart
workflow, which retain their separate qualification limits.

## Bounded inventory and source retirement

The recording reader retains at most 200 journals, 2,000 markers per segment and
4,000 markers overall. Any truncation marks the inventory incomplete, including
when every currently active filename is still present. Exact-limit inventories
remain verified when nothing was discarded. Recovery Review therefore asks the
operator to relink and inspect local files whenever checkpoint timing or segment
history is incomplete; it never presents a truncated inventory as exhaustive.
The preserved prior session and latest live checkpoint are read independently.
If either document is damaged, the other readable interruption remains available
for explicit review, alongside the error; damaged bytes remain untouched.

Source failover also fences provider reads against configuration replacement and
runtime retirement. A source removed during an in-flight read, or re-added with
the same ID after retirement, cannot return or retain the old frame. A standby
read overtaken by a blank/offline policy change cannot leak those pixels into
program. The affected tick returns no frame; the next tick uses the current
policy. Healthy sources retain their own independent cache entries.
Repeated identical health refreshes preserve in-flight healthy frames; a changed
native standby binding invalidates its in-flight lookup even if source health
and failure modes stay unchanged.

On 2026-10-21, seven focused `DesktopResilienceTests` passed from the shipping Core
source on Mac15,8, macOS 27.2 (26B118), Xcode 27.2 (27B5038j).
The compiled shipping `SessionRecoveryCoordinator`, disk store, remote-review
coordinator and `SessionRecordingJournalReader` passed
`scripts/session_recovery_harness.swift`, including exact-limit inventories,
201-segment truncation, 2,001-marker truncation and aggregate marker exhaustion.
It also checks that either corrupt checkpoint cannot hide the other valid one.
These fixtures use owned temporary directories and controlled provider callbacks;
they do not qualify physical display removal, TCC revocation, sleep/lock delivery,
Internet routes or live-provider recovery.
