# Test-only browser host and client fixtures

The reference host at `/host.html?room=<room>#<host capability>` is a **test-only browser control surface**. It shares the Worker protocol with the guest, offers explicit waiting-room admission, stage/backstage metadata, revoke/end controls, and optional camera/microphone return. It removes the fragment immediately and keeps capabilities and relay credentials only in memory. Reopening a terminal invite requires a new page/invite. A host reconnect stops local devices and requires explicit readmission before media resumes, including when a replacement host inherits an admitted roster.

Neither this page nor its status flags start StreamMac, publish Program, record media, or supply a mix-minus return. Native host integration remains a separate acceptance gate for #125–126.

From `workers/interviews`, use Node 24.15+ within major 24 and npm 12.2:

```sh
npm ci
npm run test:client
npm run test:browser
```

`test:client` needs no browser. `test:browser` requires Chrome/Chromium. It finds Google Chrome in the standard macOS location or Chrome/Chromium on Linux `PATH`; set `CHROME_BIN` to an explicit executable when needed:

```sh
CHROME_BIN='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' npm run test:browser
```

The workflow runs these in a separate five-minute browser job with stable Chrome for Testing supplied by [setup-chrome](https://github.com/browser-actions/setup-chrome). The browser fixture has a 120-second deadline and ten-second CDP request deadlines. It creates a temporary Chrome profile, uses synthetic camera/microphone devices, binds its protocol fixture to loopback only, and removes the profile when complete. It needs no Cloudflare deployment, operator secret, TURN account, camera permission dialog, or physical device. Its `ws` dependency is pinned in the package lock.

Only the disposable Linux CI job sets `CHROME_NO_SANDBOX=1` for this loopback fixture, because downloaded Chrome for Testing can encounter [Ubuntu AppArmor user-namespace restrictions](https://pptr.dev/troubleshooting#issues-with-apparmor-on-ubuntu). Local runs retain Chrome's default sandbox.

The eleven controlled client cases import the actual shipping host class. They cover immediate delivery ACKs; explicit server admission and authoritative stage state; three distinct recv-only media identities and paced ICE; matching socket/peer generations and negotiation UUIDs; a 128-candidate bound; rejection of one bad candidate without losing the answer; independent 32-message SDP queues that keep a healthy peer responsive; cached TURN on reconnect, refresh before expiry and fetch abort; late TURN/offer/device results after leave, End, socket replacement or a new negotiation; and capability, track and timer cleanup. Screen cases prove explicit host permission, denial of guest self-approval and stale grants, independent camera/screen track assignment, and control backlog failure that keeps camera media connected.

The actual Chrome fixture loads the shipping host and guest assets, applies the same static-content CSP, and uses real `RTCPeerConnection` and synthetic `MediaStreamTrack` instances. The fixture replaces the display picker with an animated canvas `captureStream`; it never captures an operator's display. It proves concurrent separately decoded camera/screen tracks and MIDs, actual screen pixels, stable source IDs, host approval/removal, screen Stop with increasing camera frame/audio packet counts, display permission denial, and late display results after permission loss or a replacement negotiation. A held noncooperative display request blocks further requests until it returns. Guest and host reconnects stop display tracks and clear permission while retaining invite source identities. The existing fragment wipe, optional host return, authoritative test stage, readmission and revoke/End cleanup remain checked. It rejects unhandled browser exceptions, including native browser API binding errors.

Its small HTTP/WebSocket server is a protocol double; it does **not** qualify the Worker. Run the separate `npm test` workerd suite for actual Durable Object, hibernation, server delivery-credit, authorization and broker lifecycle behavior. Chrome media here uses loopback ICE with inert fixture TURN credentials. These checks do **not** establish real relay connectivity, relay-only restricted networks, long-call recovery, Safari/mobile compatibility, physical device switching/permission loss, measured guest capacity, native guest composition/recording/audio alignment, or production StreamMac control.

The media APIs follow the public [W3C WebRTC specification](https://www.w3.org/TR/webrtc/). TURN refresh uses `setConfiguration` before credential expiry; recovery that needs a fresh ICE negotiation remains a manual restart/qualification gate.
