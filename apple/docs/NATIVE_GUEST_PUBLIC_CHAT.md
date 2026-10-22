# Native guest public chat return

**Share Future Public Chat** explicitly enables a read-only guest feed for the
current room/host generation/guest generation/receive lease. It defaults off,
is not persisted and is never restored on rejoin, wake, recovery or profile
replacement. The runtime binds one subscription to its existing
`StudioChatCoordinator`; account settings, sidebar, hardware actions and guest
returns retain the same authenticated provider readers. No provider socket,
OAuth flow, permission or additional subscription is created for a guest.

Only newly accepted, deduplicated public messages are eligible after opt-in.
Enable does not walk the sidebar's queue, so missed messages and earlier history
are not replayed. The queue's authoritative accepted-append result drives the
feed, including when a new item evicts an old item at its 1,000-message bound.
Stable provider IDs and tombstones retain their existing bounded replay window.

The shipping guest has a distinct **Public chat** panel. It never posts to a
provider or the host and does not share the operator's private transcript.
Text-only rows retain provider/message identity, a bounded destination hash,
platform, author, documented roles, event kind and provider/receipt timestamp.
Long text and metadata are explicitly marked as clipped. Images, emote/sticker
artwork, raw URLs, HTML, private whispers, credentials, provider write routes and
unsupported direct providers are not added to this protocol. Public braces and
markup remain literal text. Neither feed events nor opt-in change any overlay.

Each enable allocates a fresh feed UUID. `public-chat-state` and
`public-chat-message` carry that UUID, the current negotiation, monotonic
sequence, reset revision and a cumulative local omission count. Every encoded
frame is at most 1 KiB. Text starts at a maximum of 512 UTF-8 bytes and preserves
whole composed characters; JSON escaping can reduce it further. Author/platform
bounds are 64/32 bytes, roles are limited to six known public labels, and status
contains at most four actual destination receipts plus the three implemented
adapter states. Omitted status details are disclosed. Destination hashes expose
no raw account/connection identifiers. State reflects existing reader receipts;
it does not claim provider posting, a live feed or unsupported capabilities.

There is no pending-text queue or retry. At most four low-priority frames per
second are admitted, with one slot reserved for freshness state and at most
three content frames. The SDK's public-send entry point requires an empty
control buffer, so public text cannot be queued behind existing media/private
control work; an accepted frame adds at most 1 KiB. Explicit enable/Off state
uses the existing normal control path, with no more than two enables per second.
Failed/rate-limited/unsupported text is counted as locally omitted and never
resent. A provider removal advances the reset revision; later state or message
frames clear the guest display even if an immediate update was dropped. No
removed content is replayed to accomplish that reset.

The guest retains at most 32 rows, renders only through `textContent`, bounds
incoming public processing and ignores stale feed IDs, negotiations, sequences
and reset revisions. A two-second state heartbeat reports current shared
adapter/destination availability and omission counts. If no fresh state arrives
for 6.5 seconds, the guest clears its history and marks the feed stale. A later
state can resume future messages on the same lease, without repopulating history.
Every incoming public frame checks expiry before admission, so a suspended or
throttled browser timer cannot let a delayed message revive stale content.
Off, channel close and lease replacement clear the public panel. A failed Off
send revokes locally and shows **guest display unconfirmed**; the independent
guest timeout prevents an indefinitely stale enabled display. Already accepted
SDK bytes cannot be recalled. Expiry/Off/close cancels the guest timer, and
runtime retirement cancels the native heartbeat and subscription authority.

Local evidence uses `run_guest_public_chat_protocol_harness.zsh` for the actual
bounded encoder, and `workers/interviews/test/browser/guest-public-chat.mjs` for
the shipping public-panel module. The extended
`run_native_interview_manager_harness.zsh` exercises the actual Worker,
dispatcher, session, coordinator and registered sink with a controlled media
host: accepted append/eviction after 1,005 inputs, dedup/tombstone refusal,
bounded omissions, failed-Off revocation, fresh tokens, old full-lease On/Off
refusal, source closure and actual profile replacement. An expired shipping
heartbeat is deliberately queued behind a 2.1-second owned MainActor stall, then
Off/fresh On replaces its feed before it resumes; the cancelled task cannot
refresh or revoke the replacement. The full
`run_native_interview_return_audio_harness.zsh` exercises the default native
receiver, owned local Worker/Coturn and shipping Chrome page for real control
delivery alongside the existing private message and stereo audio/PTT proofs.

On 2026-10-21 the native protocol, seventeen JavaScript client tests, direct
provider HTTP/WebSocket/outbox fixtures, bounded chat model, whole-source
audience/Program renderer and extended manager/window fixture passed locally.
The rebuilt default-receiver control/media graph also passed with Node 24.15,
Chrome 155 and the owned pinned Coturn: no-history enable, Unicode/literal text,
roles/clipping, burst omissions, tombstone reset, Off, stale-heartbeat clearing,
real rejoin, retained full-lease command refusal, fresh explicit delivery and
coordinator-close retirement, with the existing private conversation, stereo
Opus return and private talkback proofs still passing. The browser module also
has deterministic suspended-timer and default-timer binding regressions.

Provider data is generated fixture input through the production public decoder;
no live provider credentials, real OAuth grant or external audience message is
used. Authorized provider feed/order/rate acceptance, deployed broker/TURN,
mobile/restricted networks and operator installation remain separate gates.
These local software proofs do not close #139 or the broader chat epic.


The guest's adapter state describes incoming public-reader health independently
of an outgoing post/moderation refusal. A healthy reader remains connected after
write permission loss. Verifying authorization, reconnecting and waiting to
resume a rate-limited reader project as connecting; failed and explicitly stopped
readers remain distinct. The native controls keep the outgoing action's own
receipt and error, without sending those write details to a read-only guest.
