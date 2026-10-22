# Restream account relay discovery

Issue #133 now includes the existing native Restream account's selected relay
endpoint rather than requiring every Restream destination to be pasted manually.
In **Destinations → Provider Accounts and Events → Restream**, refresh channels,
select a channel belonging to this account, then choose **Add Account Relay
Ingest Draft**. This reads and imports the account-wide relay; it does not attach
the selected event, enable downstream channels, or change remote metadata.

The adapter freshly reads the authorized channels and `/v2/user/ingest`, matches
that exact numeric ingest ID against the public `/v2/server/all` response, then
reads `/v2/user/streamKey`. It rechecks the selected ingest after the key read.
Every read, including public discovery, retains the same workspace intent and
actual Restream authorization generation. Account replacement, Forget
Authorization, canceled UI import, shutdown, changed selection or scope loss
rejects the result. Public server discovery receives no bearer. A current rate
refusal installs the provider cooldown; import never retries automatically.

Both `channels.read` and `stream.read` must be present in the actual token grant.
Restream's returned grant scopes are stored beside its machine credentials in
Keychain, retained when a same-account refresh omits `scope`, and removed at
sign-out/client replacement. Existing grants whose scopes were never recorded
require **Forget Authorization**, then Connect in **Settings → Chat**. Unknown
scope metadata cannot authorize stream-key retrieval.

Only the service-returned RTMP/RTMPS `/live` endpoint on a Restream host is used;
the adapter does not invent an encrypted URL from an RTMP response. Other URL
shapes fail explicitly. It does not import the returned SRT URL or infer its
entitlement. A missing, duplicate, malformed or foreign selected server fails
before requesting the key. A missing/malformed key or changed selected ingest
returns no destination credentials. These conservative bounds can reject a new
service response shape until it is reviewed.

The native destination starts disabled and carries the existing manual Restream
template and profile limits. It has no managed provider/event binding, so it
does not enter the YouTube-only managed-start gate or claim downstream event
state. Review the issued protocol, encoder profile and Restream's external
channel/event setup before enabling it. Keys/endpoints stay in the editor's
memory until Apply, then use the existing destination-ID Keychain boundary.
Portable metadata contains no key. Discovery cannot apply, publish or create a
remote event.

Upcoming encoder events also expose `coverUrl` as an explicit external HTTPS
link, alongside title, description and scheduled time. The app never fetches
the image. User information, ports, query strings, fragments and oversized URLs
are omitted independently of event state. The link is discovery metadata and
does not enter pending repair catalogs or portable destination bindings.
Restream does not define a universal privacy/latency field for each downstream
provider in this response, so those settings remain provider-side.

Run the focused actual source fixture:

```sh
RESTREAM_BUILD_PATH=/tmp/owned-restream-build zsh apple/scripts/run_restream_provider_harness.zsh
```

It compiles the exact Core, native account/API/destination/editor and Restream
authorization source with two Swift compiler jobs. The account/HTTP boundaries
use owned responses; real Keychain calls, provider consent, account secrets,
ingest sessions and provider mutations are not used. It checks secret-last
discovery, fresh ownership/recheck, public no-bearer routing, missing/unknown
scopes, malformed/foreign/changed metadata, replacement/cancel/shutdown during
held replies including a held key, rate cooldown, metadata/cover mapping,
portable/repair exclusions and the disabled manual draft. The existing native
provider account fixture also runs unchanged as a regression. These qualify
local request/state behavior, not live Restream ingest or provider approval.

Official contracts reviewed 2026-10-22:

- [Channels](https://developers.restream.io/channels/channels): account membership and `channels.read`.
- [Selected ingest](https://developers.restream.io/private-api/selected-ingest): account-selected numeric ingest ID and `channels.read`.
- [Public ingest servers](https://developers.restream.io/public-api/servers): public server IDs and actual `rtmpUrl` values.
- [Stream key](https://developers.restream.io/private-api/stream-key): `stream.read`, account key and separately nullable SRT entitlement.
- [Upcoming events](https://developers.restream.io/events/upcoming-events): encoder source filter, public metadata and `coverUrl`.
- [Token exchange](https://developers.restream.io/authentication/code-exchange): returned grant `scope` and native existing token boundary.
