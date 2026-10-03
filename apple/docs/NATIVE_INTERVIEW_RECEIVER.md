# Native interview receiver boundary

`StreamMac` compiles the application-owned C++/Swift receiver against the pinned public libdatachannel SDK. The bridge requires an explicitly registered full `GuestReceiveLease`, one active guest, distinct audio/camera/screen MIDs, and fresh ephemeral TURN configuration. It creates a new SDK peer for each service generation/negotiation. The prototype's loopback constructor remains a separate validation path.

The pinned public libjuice implementation supports UDP TURN. Every relay descriptor is bounded/validated; native construction requires at least one usable UDP TURN server. A configuration containing only TURN TCP/TLS fails `unavailable` immediately, while a mixed configuration can use its validated UDP servers. This does not qualify TCP/TLS relay or restricted-network operation.

`NativeInterviewReceiverFactory` accepts the controller's async registered-sink factory. It fences cancellation, retirement and capacity across that registration await. `NativeGuestMediaSink` sends accepted original host-clock video directly to the bounded due-frame store and audio to the explicit leased audio inlet. It does not register a guest, restamp samples, create an actor task per frame, or permit ordinary guest enqueue to register sources. Optional fixture observers run synchronously after acceptance and must remain bounded and never reenter the sink, receiver or controller.

Screen approval and sharing callbacks serialize their state and sink mutation. Both receiver and sink capture an intent before control send; control-channel closure, revocation and stop invalidate it, so a late successful send cannot restore the grant. Synchronous revocation waits for an entered receipt; later sharing callbacks cannot restore the gate. Full-lease closure clears retained video and removes only the matching audio admission, preserving replacements. The adapter withholds readiness and every media receipt until the public SDK selected-pair snapshot positively reports a local relay. A non-relay selection revokes the inlet immediately, then performs one serial retirement outside receiver/C callback locks and reports typed `unavailable`.

Production desktop archive resolution must invoke:

```sh
python3 apple/scripts/repair_desktop_transport_archives.py /absolute/owned/derived-data --require-relay-policy
```

The [owned pinned-source patch](../scripts/patches/README.md) enforces actual relay gathering/checking/selection. Missing or stale compiled implementation receipts trigger a rebuild or failure. Existing upstream archive symbols alone do not qualify this policy.

## Controlled local proof

The following commands use the actual native service/session, production adapter and registered media sink, a real local Worker, owned pinned Coturn, and the shipping guest browser code. The fixture explicitly overrides TURN provisioning with owned ephemeral local credentials; it does not qualify the deployed broker. It binds the TURN service to loopback, stores generated credentials only in private temporary configuration, bounds child lifetime/cleanup, and logs only allowed metadata.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
STREAM_GUEST_RTC_INCLUDE=/absolute/pinned-source/include \
STREAM_GUEST_RTC_LIBRARY=/absolute/verified/libdatachannel.a \
STREAM_INTERVIEW_RECEIVER_FRAMEWORKS=/absolute/owned/Build/Products/Debug \
apple/scripts/build_native_interview_media_cli.zsh

NATIVE_INTERVIEW_MEDIA_CLI=/absolute/native-interview-media-cli \
STREAM_INTERVIEW_TURN_SERVER=/absolute/owned/turnserver \
DYLD_FRAMEWORK_PATH=/absolute/owned/Build/Products/Debug \
node workers/interviews/test/browser/native-session-relay-browser.mjs
```

Coturn source is the immutable public 4.18.0 commit `23c6c1d32a3d2b21a56cee65d3203bcc4ea82d2b`, built into an owned temporary directory without installation or a system service. Fixture Node is 24.15.0. Pinned interview npm dependencies must be installed with `npm ci --ignore-scripts` first. Chrome uses an isolated temporary profile and generated animated red camera, blue screen and stereo AudioContext tone; no device request is made.

Build that fixture server using existing OpenSSL/libevent development dependencies:

```sh
STREAM_INTERVIEW_TURN_BUILD_DIR=/absolute/owned/turn \
STREAM_TURN_OPENSSL_ROOT=/absolute/existing/openssl \
STREAM_TURN_LIBEVENT_ROOT=/absolute/existing/libevent \
apple/scripts/build_owned_interview_turn.zsh
```

The helper records the exact Coturn source and binary digest, preserves its upstream notices and builds for the current host runtime. It does not install dependencies or the server. To include the actual ICE-TCP bypass regression with the positive browser fixture, set `STREAM_RELAY_POLICY_TCP_PROBE=/absolute/derived-data/TransportSourceBuild/<architecture>/relay-policy-tcp-harness`. `--policy-tcp-only` runs that focused public-API/TURN/listener proof without starting Worker/browser media. Its credentials arrive only through the private child input, and its logs contain fixed allowed result metadata.

The unpatched archive's controlled negative test uses `--expect-relay-policy-unavailable` and requires failure before readiness or any accepted pixels/PCM. It ends the actual room and checks terminal browser/native teardown. With the patched archive, the positive test requires Chrome and native **actual selected local relay** candidates, UDP byte flow, decoded red H264 camera and real stereo 48 kHz Opus PCM, then concurrent blue screen pixels through the independent MID. It checks default screen denial, approval/revocation, independent screen stop with healthy camera/audio, service rejoin with a fresh full lease/stable slot/reset grants, and actual room end with no late accepted receipt. Remote candidate kinds are reported as observed, without relabeling.

Locally qualified on macOS 27.0.1 ARM64, Xcode 26.6/SDK 26.5, Chrome 154.0.8037.95 and exact hosted Chrome for Testing 154.0.8037.92. Disposable macOS Chrome children use the public mock-Keychain testing switch; the exact .92 positive relay fixture passes without changing sandboxing or media deadlines. The macOS 14 compile target does not qualify that runtime or Intel. Separate actual `All` loopback H264/Opus/clock/loss fixtures, Chrome loopback lifecycle, and decoded guest→Composer/mixer→Program/associated ISO regressions remain required when repairing the shared desktop archive.

This proves local service/relay/registered-sink media. Shipping manager/controller entry, deployed TURN broker, Internet/mobile/restricted networks, physical devices, mix-minus/AEC and signed installation require their separate acceptance evidence.
