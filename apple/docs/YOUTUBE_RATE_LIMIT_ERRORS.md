# YouTube live request throttling

`ProviderFailure.check` recognizes `userRequestsExceedRateLimit` as a rate/quota failure. Previously its HTTP 403 response fell through to permission repair, so the native account session did not activate its existing cooldown.

Google documents this reason for Live Streaming operations, including HTTP 403 on `liveBroadcasts.transition`: [YouTube Live Streaming API errors](https://developers.google.com/youtube/data/live/reference/rest/v3/errors), reviewed 2026-10-22 (page updated 2026-10-15). This change adds only that documented reason; it does not infer account eligibility or app approval.

The existing numeric `Retry-After` policy stays bounded to 0–86,400 seconds and rejects nonfinite/unparseable values. The session retains its existing minimum one-second/default 60-second cooldown policy. `liveStreamingNotEnabled`, `livePermissionBlocked`, `insufficientLivePermissions`, and unknown HTTP 403 reasons remain permission failures.

Regression coverage:

- `ProviderAPITests.liveRequestRateLimit` calls the shipping classifier with the documented HTTP 403 body and finite, oversized, negative, nonfinite, malformed and absent numeric retry headers; raw provider text stays redacted. `livePermissionFailures` retains eligibility/approval/unknown-reason controls.
- `provider_accounts_harness.swift --youtube-rate-limit-only` uses the actual vault and account session with explicit memory credentials/retirement, owned temporary pending storage, and injected HTTP. It seeds verified YouTube/Twitch accounts, checks permission controls, verifies exactly one failing GET and a 120-second cooldown, suppresses subsequent YouTube metadata/chat GETs, and completes a healthy Twitch read. No browser/OAuth callback, real provider request or personal credential store is used in that focused mode. The pre-existing HTTP 429 case remains in the full harness.

Validation on 2026-10-22 after the coordinated quiet window passed on the first attempt: a fresh ARM64 Debug framework built from all 76 shipping Core sources, all 609 Core tests in 83 suites (all 58 test files, including the two new tests), optimized strict Swift 6 compilation of the actual provider-session harness, and the focused `--youtube-rate-limit-only` runtime case. The full session harness was compiled; only its focused mode was executed in this validation. The unchanged HTTP 429 session case was retained in source. Existing Core tests used only their dedicated `com.joeblau.Stream.tests.*` synthetic Keychain services; the focused session used injected memory stores. No real provider account or service was contacted.

The exported framework binary SHA256 is `ed355819476e845e57266ca5992221a1270c505002fc8efde16cf1b304e57d4d`. Exact commands, source hashes and original logs are retained under the owned validation folder `apple/build/youtube-rate-limit-validation/`; `results.json` records every stage exit 0. This is a repair of provider error handling, not live-account qualification or completion of #133/#169.
