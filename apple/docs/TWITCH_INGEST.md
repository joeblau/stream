# Twitch public ingest discovery

The Twitch account panel now has **Discover Twitch Ingest Servers** and a picker
for the returned endpoints. The fixed public GET is
`https://ingest.twitch.tv/ingests`; no bearer, client ID or stream key is sent.
Discovery starts only on an explicit button press. It does not choose an
endpoint automatically or treat the reserved `default`, `availability` or
`priority` fields as latency/health measurements. The operator deliberately
selects an endpoint, or enters one separately issued by Twitch.

The bounded parser accepts numeric unique IDs and a returned RTMP/RTMPS
`/app/{stream_key}` template on the documented Twitch ingest host families.
It removes only the exact terminal placeholder to produce the endpoint; it
never inserts a key in the public URL. Unknown hosts, URL credentials/query/
fragments, duplicate IDs and malformed templates fail rather than being
guessed. New provider URL shapes can require a reviewed compatibility update.
Empty, failed and malformed responses remain unavailable. A rate-limit
response installs a bounded cooldown; retry is explicit and no request is
replayed automatically.

Provider/channel changes, a new discovery and view dismissal cancel the old
target. Late successes and errors cannot overwrite the replacement list,
selection, failure or cooldown. Explicit selection resolves only an ID from
the matching current target; a stale picker ID cannot choose a new channel's
endpoint. Editing the manual endpoint clears a mismatching picker selection.

Import separately re-reads the authenticated broadcaster and verifies the exact
selected channel. Both this GET and the stream-key GET retain the same machine
credential generation and workspace intent, checking the actual
`channel:read:stream_key` grant. Replacement credentials or canceled/closed
workspace work cannot return a late key. The imported destination remains
disabled and manual: it has no provider binding that would enter the
YouTube-only managed-start gate. Apply uses the existing stable destination-ID
Keychain storage, and the producer starts it deliberately.

The focused fixture runs with the Restream regression:

```sh
RESTREAM_BUILD_PATH=/tmp/owned-provider-build zsh apple/scripts/run_restream_provider_harness.zsh
```

It compiles the actual public client, Core parser, account/vault import,
destination draft and SwiftUI picker source. Controlled HTTP covers public
no-bearer GETs, exact target/ID selection, malformed/foreign/duplicate/template
refusal, reserved fields, HTTP failure, rate cooldown, cancellation of held
success and refusal replies, replacement targets and held own-channel/key
replies across account replacement/cancellation. It creates a real disabled
in-memory manual draft. It performs no consent, authenticated external request,
provider mutation, stream-key retrieval from a user account or live ingest.

Official references reviewed 2026-10-22:

- [Get Ingest Servers](https://dev.twitch.tv/docs/video-broadcast/reference/): public fixed URL, response templates and reserved fields.
- [Video broadcasting](https://dev.twitch.tv/docs/video-broadcast/): endpoint/key composition and separately available `bandwidthtest=true` mode.
- [Get Stream Key](https://dev.twitch.tv/docs/api/reference/#get-stream-key): authenticated broadcaster and required grant.

A public endpoint list and local transport/profile tests do not establish an
account's actual ingest acceptance. Twitch bandwidth testing still requires an
authorized account key and is outside this controlled fixture.

On the named local review host (Mac15,8, macOS 27.2 / Xcode 27.2), an
unauthenticated public read returned 14 Twitch endpoints, including
`ingest.global-contribute.live-video.net`; the exact production parser accepts
all 14. A separate public Restream read returned 19 servers, all accepted by the
actual selected-ingest mapper with locally injected selection IDs. These are
public routing observations, not authorized account or live ingest tests.

Import controls keep the captured endpoint fixed while its key read is in
progress. Completion checks the exact attempt/provider/channel/endpoint again
before adding a draft. Private account GET rate limits also establish the
account cooldown, with stale/canceled refusals discarded. A current refresh
revocation uses the vault's exact revoked-successor receipt to offer
reauthorization, while a replacement account's failure cannot poison the new
account. Successful completion always requires the original credential.
