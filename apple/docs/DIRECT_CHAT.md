# Shared direct public chat

Reviewed against official provider documentation on 2026-10-02. The native account panel and chat sidebar observe the same `StudioDirectChatManager`, bound once with `chat.bindAccounts(providerAccounts)`. Public messages flow into `StudioChatCoordinator.receive(StudioChatAction)`, its bounded queue, existing favorites/filter/reading-position controls, staged Program comment slots, and existing hardware/guest consumers. They do not create another OAuth session or socket per view. Direct connect/read/send/delete actions never start automatically after login, project load, wake or restart.

Guests can receive an explicitly enabled, read-only stream of future public
messages from this same coordinator. The full-lease opt-in, bounds, freshness
and no-replay behavior are described in [NATIVE_GUEST_PUBLIC_CHAT.md](NATIVE_GUEST_PUBLIC_CHAT.md).

| Provider | Implemented reader and verified target | Optional explicit actions | Limits |
| --- | --- | --- | --- |
| YouTube | Fresh owned broadcast ID lookup must return the OAuth-selected channel, live lifecycle and `snippet.liveChatId`; REST `liveChat/messages.list` follows its page token and `pollingIntervalMillis`. | Public text post, targeted delete, 10-minute timeout and permanent ban through the owned chat with granted `youtube` or `youtube.force-ssl`. | Initial history is limited to what the API returns. REST polling consumes quota; preferred streaming/gRPC `streamList` is not implemented. No threaded reply API is exposed. Composer conservatively caps text at 200 characters as an app limit. |
| Twitch | Fresh validated user-token identity; own authorized broadcaster only; public EventSub WebSocket with `user:read:chat`. Connection is acknowledged only after enabled message/delete/clear/clear-user/public-notification subscriptions are returned. | Public post/reply requires `user:write:chat`; targeted deletion requires `moderator:manage:chat_messages`; timeout/ban requires `moderator:manage:banned_users`. | Public Device Code Flow requests only optional grants explicitly selected in the account panel. No cloud/app-token bot, other-channel moderation, private whispers, pins, unban, role changes or AutoMod controls. User-token sends may reach every participating Shared Chat channel; composer discloses this before confirmation. |
| Restream | Existing public aggregated reader; adapter resets preserve other providers and local curation. | Existing staged comment actions. | No provider write is inferred from relay identity. Restream public replies/moderation are not implemented. |
| Other direct providers | Explicitly unavailable. Ordinary relay publishing remains available. | None. | An ingest credential proves neither chat access nor an approved provider connector. |

Writes require operator confirmation and current connected/granted/owned context. The composer starts with no selected destination; a review captures exact account, broadcast and reader generation. An account or broadcast change invalidates the review. Each chosen provider receives one request and a separate receipt, including partial success. Send requests honor Twitch `is_sent` and create no local message echo. A missing/rejected/uncertain response is not treated as delivered. **Stop Waiting** cancels local work. A write operation that has begun reports an unknown provider outcome because cancellation cannot undo a provider action; cancellation before it begins reports not sent. Nothing is automatically replayed after reconnect, cooldown, cancellation, project change or recovery.

Deletes always supply the selected provider message ID: Twitch never sends a delete without `message_id`, which would clear a channel. Timeout and ban require a separate author/target confirmation. Owner/moderator messages are conservatively protected; Twitch messages older than six hours cannot be deleted locally. API permission checks can still reject a grant. Successful delete responses and validated ban resources remove only known matching messages, favorites and queued selections, including a staged featured comment. An uncertain response leaves local messages intact. Staged changes reach Program with **Take** unless Direct Live Editing applies them immediately.

Twitch timeout/ban uses `moderation/bans` with the token's verified user as moderator; timeout sends a fixed `duration: 600`, and permanent ban omits duration. Returned author/broadcaster/moderator IDs must match; permanent bans require a null `end_time`. [Twitch Ban User](https://dev.twitch.tv/docs/api/reference/#ban-user). YouTube submits a `temporary` or `permanent` live-chat ban with the selected author's channel ID; timeout explicitly sets `banDurationSeconds: 600`. Returned ban identity, target, type and temporary duration must match. [YouTube insert](https://developers.google.com/youtube/v3/live/docs/liveChatBans/insert), [ban resource](https://developers.google.com/youtube/v3/live/docs/liveChatBans).

Presets store only producer-authored names and text in project-local `chat-presets.json`: at most 32 entries, names up to 64 characters, text up to 500 characters and 4096 UTF-8 bytes. Loading a preset neither selects targets nor sends it. Portable export includes presets, remaps their IDs, and preserves literal message text. Unreadable, oversized or future-version preset files are preserved without overwriting. Action history stays in memory with at most 64 bounded receipts and one outstanding action per provider; there is no pending-send queue. Targets, credentials, incoming messages and receipts are never saved in presets, recovery or diagnostics.

YouTube text, Super Chat, Super Sticker, membership, milestone and membership-gift events use documented display text and author roles. Twitch documented emote fragments classify the message as **Emotes**, while preserving its exact public text. No CDN URLs, prices, reaction counts, image emotes, remote HTML, or viewer metrics are guessed. Avatar URLs are bounded HTTPS metadata only; this adapter does not fetch them. Native event badges, separate filters, text-card palettes and manual staged alert promotion are described in [AUDIENCE_EVENTS.md](AUDIENCE_EVENTS.md); [manual static Twitch emotes](STATIC_TWITCH_EMOTES.md) use explicit provider metadata and the existing authorized reader for **Show emote** in native chat and separate staged tiles, while animated/sticker artwork remains unavailable.

The existing YouTube reader also recognizes documented `giftEvent` records as
Gift, using only their bounded public `displayMessage` and normal author fields.
Gift asset URLs, amounts, durations, visual effects and combo metadata stay
unused; the event is read-only for per-message reply/moderation. Google allows
the same gift ID to recur for combo updates. Current first-identity dedup keeps
the original displayed caption and does not generate repeated alerts or claim
a live combo counter. Existing ordinary/membership action eligibility is
unchanged. See the [current resource contract](https://developers.google.com/youtube/data/live/reference/rest/v3/liveChatMessages)
and [owned decoder/manager controls](YOUTUBE_GIFT_EVENTS_2026-10-22.json).

The same deliberately connected Twitch reader subscribes to documented public
`channel.chat.notification` v1 with its existing `user:read:chat` grant. Ordinary
`sub`, `resub`, `sub_gift` and `community_sub_gift` notices become Membership,
Milestone and Gift entries. The provider's public system text and user text
remain literal, with one separator and a combined 16 KiB limit. Anonymous
notices discard person IDs, names and badges even if contradictory fields are
present. Shared-chat, unknown and other notice types stay unsupported. These
provider notices are read-only for reply/moderation; ordinary chat message
actions retain their existing permissions. No new consent, media URL, amount or
remote artwork is inferred. See [Twitch's subscription contract](https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/#channelchatnotification),
[public event fields](https://dev.twitch.tv/docs/eventsub/eventsub-reference/#channel-chat-notification-event),
and the [controlled proof receipt](TWITCH_PUBLIC_NOTICES_2026-10-22.json).

The **Destination audience** panel offers an explicit **Refresh** for each currently connected, owned direct chat. It reads YouTube `videos.list` (`snippet,liveStreamingDetails`) for the verified broadcast or Twitch `Get Streams` for the verified broadcaster, using the same authenticated account request boundary. Returned channel, broadcast and active chat must match the current reader generation. Counts are separate provider-reported concurrent viewers; no unique-person total or cross-platform sum is calculated. Missing/hidden counts display **Provider did not expose a count**; an ended/absent live stream displays **Broadcast offline**, and neither is converted to zero. Successful counts include observation time, become stale after 60 seconds, and can refresh at most every 30 seconds. A failed refresh retains the last known sample with failed/stale labeling and honors a provider rate-limit delay. Metric failures do not cancel incoming readers or reset the curated queue. Disconnect, account replacement and reader failure cancel metric work and reject late responses. There is no automatic polling or refresh after login/restart. Restream/other provider metrics, animated emotes and sticker artwork remain explicitly unavailable; manual static Twitch emote tiles use the separate opt-in metadata path described above.

Real provider message IDs deduplicate by provider/message identity across reconnects and across a Restream relay carrying that same ID. Envelopes without a provider message ID retain separate deliveries. The first received adapter supplies display/routing metadata. Shared Chat copies with different provider IDs cannot be correlated by content. Queues retain at most 1,000 messages with bounded curation and 4,000 identity tombstones; routes also cap at 4,000. A moderation replay within that bounded window cannot resurrect deleted text. Receipts remain in memory, never in project configuration or diagnostics.

Twitch requested migration opens the provider-issued, validated EventSub URL as-is, continues the previous socket until the new welcome, then retires it; transferred subscriptions are not created again. A lost session resubscribes on a fresh session, with at most three exponential retry attempts per manual connection. Welcome and keepalive deadlines cancel stalled sockets. A disconnect cannot replay missed messages and is disclosed as a gap. Authorization replacement/logout/workspace shutdown cancels that provider's work and ignores late HTTP, socket and mutation acknowledgments. A failure or stop in one reader preserves healthy other readers and local curation. Permission refusal disables related write actions until deliberate reconnect and fresh authorization verification, without stopping incoming chat. Rate-limited YouTube reads retain their queue and retry the same page only after the account's cooldown; no public send or moderation request is replayed.

## Primary sources

- [YouTube list](https://developers.google.com/youtube/v3/live/docs/liveChatMessages/list) defines the REST query, returned history/order, page token and poll timing; [streamList](https://developers.google.com/youtube/v3/live/docs/liveChatMessages/streamList) is the preferred streaming alternative, not claimed implemented here.
- [YouTube video resource](https://developers.google.com/youtube/v3/docs/videos#liveStreamingDetails.concurrentViewers) documents conditional/hidden concurrent viewer counts and ended broadcasts. [Twitch Get Streams](https://dev.twitch.tv/docs/api/reference/#get-streams) documents broadcaster filtering and concurrent `viewer_count`. These references were checked on 2026-10-21.
- [YouTube public message resource](https://developers.google.com/youtube/v3/live/docs/liveChatMessages), [insert](https://developers.google.com/youtube/v3/live/docs/liveChatMessages/insert) and [delete](https://developers.google.com/youtube/v3/live/docs/liveChatMessages/delete) define displayed event types/roles, tombstones, public text posting, authorization and owner/moderator deletion.
- [Twitch chat authorization](https://dev.twitch.tv/docs/chat/authenticating/), [EventSub subscription types](https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/) and [event payloads](https://dev.twitch.tv/docs/eventsub/eventsub-reference/) distinguish installed user-token scopes and documented public notifications.
- [Twitch WebSocket lifecycle](https://dev.twitch.tv/docs/eventsub/handling-websocket-events/) defines welcome/keepalive/migration and missing replay after unexpected disconnect. [Subscription creation](https://dev.twitch.tv/docs/api/reference/#create-eventsub-subscription), [public send](https://dev.twitch.tv/docs/api/reference/#send-chat-message) and [targeted deletion](https://dev.twitch.tv/docs/api/reference/#delete-chat-messages) define actual API acknowledgments, shared-chat behavior and deletion limits.

## Validation and remaining acceptance

`apple/scripts/run_direct_chat_harness.zsh` compiles the production native manager, preset store, socket boundary, public decoders and common queue under Swift 6. Injected HTTP/WebSocket fixtures exercise exact requests and acknowledgement resources, independent multi-provider receipts, permission loss, same-provider incoming messages after write refusal, read/write cooldown isolation with identical resumed page token, targeted deletion/tombstones, temporary/permanent moderation, protected/read-only roles, bounded Unicode/history/preset files, portable text preservation, restart, account changes and noncooperative late responses. Existing cases retain poll intervals, public event kinds, cross-adapter deduplication, old-socket delivery during migration, no migrated resubscription and fresh resubscription after loss. Additional audience fixtures verify explicit exact-target reads, independent samples, missing/offline versus zero, bounded integer parsing (including Boolean/negative/fraction rejection), freshness/throttling, failure/read continuity, rate limits, late cancellation, held success/error completion during same-generation reconnect, and typed alert eligibility. Provider OAuth tests verify optional scopes are explicitly selected, and the provider-account harness checks cooldown short-circuiting without another network request. Run these reproducible commands from `apple/` with Xcode 26.6 selected:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer scripts/run_direct_chat_harness.zsh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer scripts/run_provider_accounts_harness.zsh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -project Stream.xcodeproj -scheme StreamCoreTests -destination 'platform=macOS' -only-testing:StreamCoreTests/ProviderAPITests -only-testing:StreamCoreTests/PortableShowTests CODE_SIGNING_ALLOWED=NO test
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild -project Stream.xcodeproj -scheme StreamMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The #142 change passed the native manager and account harnesses, 19 provider/portable Core tests, and full native application builds with Xcode 26.6 and 27.2. Injected responses exercise production code; they do not establish live service authorization or delivery.

No authorized public live feed, approved application grant, or external user message was used for validation. Real Google/Twitch consent and read acceptance, live ordering/rate behavior, provider-side send/reply/delete/timeout/ban acceptance, and actual Program presentation with an authorized feed remain acceptance blockers for #139/#142. Test with deliberately chosen owned feeds and consenting test authors, including partial-provider refusal, account disconnect and an uncertain send outcome; inspect the provider before any manual retry. Authorized live viewer-count accuracy/freshness, real provider event feeds, and visual Program inspection of promoted events remain #143 acceptance gates. Manual static Twitch emote tiles are available through the explicit authorized metadata path; animated emotes, sticker artwork, reaction feeds and automatic alerts remain unsupported. Manual alert promotion uses the separate staged alert slot with its explicit opt-in; Take publishes it. A fixture pass is local software evidence, not provider acceptance.

## Integration hook

Root runtime owns account/coordinator construction. Add only `chat.bindAccounts(providerAccounts)` after constructing its retained account session; preserve root's newer recording-message/fingerprint properties when merging coordinator changes. Existing `chat.shutdown()` stops both direct readers and Restream. `providerAccounts.shutdown()` stops readers as well, without deleting machine credentials. Views reuse the retained manager in sidebar and account settings. No workspace/app entry point is modified by this isolated change.


## Local audience validation (2026-10-21)

The production direct-chat manager/decoders/outbox and audience fixtures passed with the selected Xcode 27.2 Beta 3 compiler against the current SDK-compatible `apple/build/mac/Build/Products/Debug/StreamCore.framework`. The public Restream queue harness also passed. Reuse an existing SDK-compatible Core build without generating/building the Xcode project:

```sh
CHAT_PRODUCTS_PATH="$PWD/apple/build/mac/Build/Products/Debug" zsh apple/scripts/run_direct_chat_harness.zsh
zsh apple/scripts/run_studio_chat_harness.zsh
```

 Native fixture coverage is software evidence and does not establish an authorized provider session or actual live service delivery. The SwiftUI/coordinator changes require the integrated app validation performed by the root task; no external messages or account mutations were sent for these checks.


## Shared reader status and retained message targets

Guest public status describes the incoming reader independently of outgoing
post/moderation failures. A connected reader stays **connected** after a write
permission refusal; authorization/reconnect/read cooldown transitions report
**connecting**, a failed reader reports **failed**, and an explicitly stopped
reader reports **offline**. Outgoing refusals remain visible in native action
receipts and account controls. They do not falsely mark the read-only guest
feed as failed.

Historical public messages remain in local curation after a broadcast change,
but a reply/moderation review target exists only when its original provider,
channel and chat match the currently connected reader. A replacement broadcast
cannot be named as the target of an old-chat message. Such messages remain
read-only; rejected local actions issue no HTTP request. Same-chat history can
still use the current reviewed target while its supported action remains
available.


Cancellation before a scheduled write operation starts is checked again at the
manager's request boundary. It produces **Not sent · Canceled before provider
dispatch** without invoking the post/delete/timeout/ban HTTP request. Once the
operation has begun, **Stop Waiting** keeps its existing unknown-outcome receipt;
it cannot undo an external side effect. This distinction does not enqueue or
replay a canceled action and does not stop the incoming reader.


Each workspace pins chat request authority to its successfully verified identity
and machine-credential generation. Replacing authorization in another workspace
cannot make a future old-reader request adopt the replacement user's token.
Reads and mutations fail before HTTP, the old direct reader retires, and a
fresh deliberate connection/identity verification is required. A normal access-
token refresh preserves that generation and continues serving both verified
workspaces. Identity verification is also fenced by workspace intent and an
attempt token, so a late superseded verification cannot replace a newer pin.
The two-session fixture uses one controlled vault and transport; it establishes
no real OAuth grant or authorized audience feed.
