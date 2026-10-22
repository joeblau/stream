# Restream authorization broker

Restream documents a confidential client-secret requirement and instructs user devices to refresh through an application server. Native Stream now uses the companion `workers/restream-auth` service. It never exchanges a provider code or refresh token directly, never requests or reads a client secret, and never falls back to the old native flow. Google desktop PKCE and Twitch public device authorization are unchanged.

In macOS/iOS Settings → Chat, enter only the root HTTPS URL of a trusted configured service, then choose Connect. The service must have a registered Restream application, its HTTPS `/oauth/callback` registered with Restream, its `PUBLIC_ORIGIN` and public client ID configured, and its confidential secret provisioned server-side. None is deployed or provisioned by this change. Without this service, authorization remains unavailable. Ordinary manual ingest remains available independently.

The native client creates a random verifier and state. The broker stores only its S256 challenge and creates an independent random provider state. The system browser visits Restream's official login URL with the broker's HTTPS callback. The broker atomically spends state before code exchange and retains the provider token pair server-side. Its fixed `streamchat://oauth` return contains attempt/state only: no provider code, refresh token or access token. Native validates that return and submits its verifier to the broker. Completion is one-use; interception of the custom scheme does not supply the verifier. This is S256 between native and broker, not a claim that Restream implements PKCE.

Native Keychain stores only the scoped access bearer, actual granted scopes, expiry, broker session ID and opaque broker credential in a bounded atomic broker-grant record. The service URL is separately saved. Entries are device-bound. Legacy direct-native credentials remain preserved and inactive; they are not read, migrated or deleted. No broker credential is stored in portable projects, repair catalogs or diagnostics. Explicit sign-out first writes a nonsecret local retirement marker, then clears the active broker grant and requests best-effort deletion of that broker session; it does not claim provider-side OAuth revocation. The marker prevents a failed Keychain deletion from reviving the stored grant on relaunch. Failed local cleanup is visible with a Forget Stored Authorization retry action. New grant persistence clears the marker only after its Keychain write succeeds. If all local writes are unavailable, the app reports failed cleanup rather than claiming durable sign-out; repair local storage and retry. Server TTL bounds abandoned attempts (10 minutes) and sessions (30 days).

A process-local authority lease covers the one machine Restream account across workspaces. A new deliberate authorization/configuration retires old workspaces before they can accept a held grant, refresh it into the shared Keychain or issue future authenticated requests. A retired workspace cannot erase a replacement grant on sign-out. Normal same-account refresh preserves authority and coalesces. Closing one workspace or choosing Cancel Connection while connecting cancels its work without revoking a healthy workspace's account. Both settings panels expose cancellation before the browser opens and during socket connect/reconnect. Runtime attempt/task fences reject late successful and failed responses.

The broker uses one SQLite-backed Durable Object per attempt/session. It persists callback spend and refresh ownership before external requests. Concurrent refresh callers share the owned rotation. Requests include the digest of the last known access token; after a lost response, the broker returns the already-persisted replacement without reusing its predecessor's rotating provider refresh token. An interrupted/cold rotation requires fresh consent instead of guessing whether a refresh token was spent. Forget/expiry cannot be undone by a held response. All provider traffic uses the fixed official token URL, no redirects, a timeout and bounded JSON. Errors disclose no provider bodies; logs are disabled by default. Public attempt creation has an IP rate limit and no browser POST/CORS grant.

Validation commands:

```sh
cd workers/restream-auth
npm ci
npm run typecheck
npm test
npm run build # local dry-run bundle only
# Native, from the repository root, optionally through the shared build-slot helper:
BROKER_BUILD_PATH=/tmp/owned-broker-build zsh apple/scripts/run_restream_broker_harness.zsh
```

The native harness compiles exact Core/client/runtime and shipping Restream controller with an owned protocol witness and nil Keychain. It exercises state/duplicate/callback/replay checks, opaque-only persistence, coalesced refresh, canceled begin/complete/refresh, failed persistence, two workspaces sharing authority and the unconfigured shipping gate. The workerd tests use a Miniflare-owned outbound provider at the actual HTTPS fetch boundary; no external provider is contacted. They cover confidential exchange location, state/proof/replay, stored refresh rotation, lost-response recovery, concurrent callers, revocation during held refresh and during cached-recovery hashing, expiration, failure redaction, malformed input and persisted interrupted ownership. Parent integration builds qualify macOS/iOS source inclusion.

Deployment, secret provisioning, actual Restream consent and live account/chat/ingest acceptance remain unqualified. This is a reviewable implementation, not a deployed authorization service or whole-issue #133 completion.

Official contracts: [Restream authorization](https://developers.restream.io/authentication/authorize-dialog), [code exchange](https://developers.restream.io/authentication/code-exchange), [refreshing tokens and device/proxy guidance](https://developers.restream.io/authentication/refreshing-tokens). Reviewed 2026-10-22.
