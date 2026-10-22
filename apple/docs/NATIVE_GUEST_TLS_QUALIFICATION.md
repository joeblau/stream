# Optional TURN/TLS backend: owned control and partial media proof

The optional source-built libnice backend now performs real verified TURN over
TLS. ARM64 public-SDK relay-only bidirectional control passes through a sole
TLS-only owned Coturn listener. Wrong-CA and wrong-IP-identity cases fail before
application plaintext is admitted. The shipping SDK and default UDP-only
receiver capability remain unchanged. **Full native/Chrome TLS media, return
audio, rejoin and A/V acceptance remain unqualified.**

[Machine receipts](NATIVE_GUEST_TLS_2026-10-22.json) retain exact source,
artifact, deployment-floor, negative-control and failed-media evidence. This
extends the earlier [macOS 14 TCP source closure](NATIVE_GUEST_TCP_PORTABILITY.md);
its Intel/TCP results do not establish Intel/TLS behavior.

## Source and capability boundary

The build uses the same pinned libnice `ae3eb16fd7d1237353bf64e899c612b8a63bca8a`,
public SDK `8c31097ea78f051e857d0aa1b2f6efb26cd12b7e`, OpenSSL
`c8bd5a57108599ac650bbae77fcabe3109dab2e8` and owned GLib dependency closure.
No new global dependency or SDK installation is needed. All 14 merged archives
declare minOS 14.0; actual execution was on Apple Silicon/macOS 27.2.

The pinned libnice source exposes a TLS relay enum but its standards-based
[TCP socket creation path](https://github.com/libnice/libnice/blob/ae3eb16fd7d1237353bf64e899c612b8a63bca8a/agent/agent.c)
does not provide this real verified TLS layer. The reviewed optional patch adds
an OpenSSL memory-BIO NiceSocket inside the actual socket chain. It is not a
plaintext tunnel or local proxy. TLS requires version 1.2 or newer, a verified
chain and the original IP SAN or DNS hostname. DNS uses explicit hostname
verification and SNI; only the IP SAN path has actual runtime evidence here.
See OpenSSL's [hostname verification API](https://docs.openssl.org/3.6/man3/SSL_set1_host/).

Plaintext queues, individual messages and pending ciphertext have fixed bounds.
No application plaintext enters `SSL_write_ex` before the handshake verifies.
Socket operations use the existing agent lock. Writable resumption looks up TLS
through a currently owned socket source/GSocket and compares the potentially
retired callback pointer only as an identity. A real libnice regression passes
an inaccessible `PROT_NONE` address through live and retired source ownership;
it is targeted lifecycle evidence, not general race/sanitizer certification.
Configured proxies and non-RFC5245 TLS compatibility modes explicitly refuse.

The optional SDK patch also fixes `turns:host?transport=tcp` being parsed as
clear TCP. The secure scheme continues to require TLS, and `turns` plus UDP is
refused because DTLS TURN is not implemented. This follows
[RFC 7065](https://www.rfc-editor.org/rfc/rfc7065.html). Public SDK configuration
layout is unchanged.

Compilation requires explicit `build_owned_nice_transport.py --turn-tls`.
The receiver requires **both** `STREAM_NATIVE_NICE_TURN_TCP` and
`STREAM_NATIVE_NICE_TURN_TLS`, plus matching compiled backend markers.
An exported symbol alone cannot enable TLS in default or TCP-only builds.
The builder records `ownedTLSImplementation:true` and `tlsQualified:false`;
compilation does not grant runtime or release qualification.

## Actual control and trust results

Final ARM64 backend SHA-256:
`c7df56076fd3876ae72c8911d9c1ca29a5d067cd3998c92c47761f7d4c29415c`.
TLS 1.3 was independently verified at the server endpoint. Coturn exposed only
its owned TLS TCP listener, with no clear TCP or UDP TURN listener. Both native
peers selected relay candidates and maintained four actual TCP connections.
The relay allocation remains UDP; that does not describe the client/server TLS
connection. This is a controlled local restriction, not an OS firewall test.

| Actual case | Verified handshakes | Failed handshakes/sockets | Admitted plaintext out |
| --- | ---: | ---: | ---: |
| Trusted owned CA + IP SAN | 4 | 0 | 7,652 bytes |
| Unrelated owned CA | 0 | 4 | 0 |
| Trusted CA + wrong IP SAN | 0 | 4 | 0 |

The diagnostic field named `rejected` counts fatal TLS/socket errors and
timeouts generally, including unused connections; it is not a dedicated
certificate-error classification. Negative controls also require no received
application message. Private keys and temporary TURN credentials are never
printed and are removed with the mode-0700 owned fixture directory.

Native trust is an explicit per-process CA file copied to each owned agent.
Without it, OpenSSL uses its compiled default trust paths and fails closed;
macOS Keychain/system-root integration is not implemented or qualified.
The actual Chrome fixture uses a fresh profile and the one ephemeral leaf SPKI
with Chromium's [process-scoped verifier switch](https://chromium.googlesource.com/chromium/src/+/HEAD/services/network/ignore_errors_cert_verifier.h).
No system trust, Keychain, DNS or network settings change. That fixture trust
exception is not a release trust model.

## Actual native Manager attempt and retained failure

A fresh full-source CLI was compiled from `d413aa1`, with the optional receiver
gate, TLS diagnostic counters, current Manager/controller source and an
explicit owned unlocked resilience coordinator. Generated fixture boundaries
refuse physical microphone startup and isolate defaults/storage/credentials.
The shipping lock guards remain in the generated controller. VoicePolish is
configured Off in the fixture. The current TLS CLI SHA-256 is
`39a4b4232060c4e471a0e588fbd48364cdc931b2f920927ab8f850a428607592`, minOS 14.0.

The real local Worker, Manager/default receiver and Chrome 155.0.8059.85 reached
connected TLS media. The bounded explicit-null-context/muted-player attempt
recorded **28 native decoded camera frames and seven admitted Opus packets**,
with two verified native TLS handshakes. One alternate socket failed; no
certificate bypass was enabled in native code.

The full flow then correctly **failed** the existing return PCM gate. The real
48 kHz direct-track AudioWorklet processed 284,672 frames, but both channel RMS
values and every expected tone magnitude were zero. Expected local return
amplitudes remained 0.4/0.2, with the original tolerances. No threshold was
relaxed. A subsequent native positive control ruled out the proposed initial
microphone-denial cause: capture-route admission was true and the OS microphone
status was not denied, both idle and during the active failure. Native Program
retained actual local magnitudes 0.399936/0.200005 while Chrome observed zero;
no synthetic permission grant was applied. The cause remains unclassified
across return sender/browser null-sink consumption. This does not establish
positive return audio or the later screen,
private-control, source-transition, rejoin and synchronization checks.

Earlier normal-context attempts remain failed: synchronous cold AudioContext
startup exceeded the unchanged ten-second CDP deadline, or the connected
native session admitted zero incoming audio. Scheduling actual preparation
observes its real completion with a bounded 45-second deadline, without a fake
AudioContext, fake `resume`, fake tracks or fabricated stats. The separate
`--owned-null-contexts` mode verifies real `sinkId:{type:'none'}` contexts and
mutes only its owned HTML player; it cannot be used for AV qualification. Even
that explicitly scoped attempt failed positive return PCM. No normal HTML audio,
rendered PCM, physical/browser AEC or playout A/V success is claimed.

## Reproduce in owned paths

Use the dependency/source-build recipe in the TCP portability document, adding
`--turn-tls --source-bundle` to the optional backend build. The exact reviewed
TLS patches and per-file output hashes are checked before applying; unrelated
working/index changes are refused without deleting them. Source bundles retain
the patches, recipes, pinned component archives and upstream license texts.
This retains review/relink materials; it does not adopt a redistribution model.

```sh
python3 apple/scripts/run_owned_nice_tcp_smoke.py \
  --backend-build-dir /absolute/owned/tls-backend \
  --output-dir /absolute/owned/tls-trusted \
  --turnserver /absolute/owned/turnserver \
  --openssl /absolute/owned/openssl/bin/openssl --tls
```

Repeat with separate outputs and `--reject untrusted` / `--reject identity`.
Run `run_owned_nice_tls_lifecycle.py` with `--backend-build-dir` and a separate
`--output-dir` for the actual retired-identity callback regression.

`prepare_owned_nice_media_cli.py --tls` takes explicit `--backend-build-dir`,
`--reference-derived`, `--vendor-root` and a **fresh** `--output-dir`. It uses
the existing full-source fixture generator and copies the reference derived
tree without modifying it. Only the owned macOS transport artifact is overlaid,
and its copied XCFramework metadata declares the actual single architecture.
Other platform slices are preserved. It emits source/backend hashes and a
generated project; it does not claim that the project has been built or run.

Build that project's `NativeInterviewReturnAudioCLI` with `-jobs 2`, generated
Swift `-j2` settings, the owned derived directory, and
`STREAM_GUEST_RTC_INCLUDE=<owned-derived>/Build/Products/Debug/include/libdatachannel`.
Use the shared native build-slot wrapper for builds and media runs. Then run
`native-interview-return-video-browser.mjs --video-flow-only`, supplying the
owned CLI/framework directory, pinned Coturn, `STREAM_INTERVIEW_RELAY_TRANSPORT=tls`
and `STREAM_INTERVIEW_TLS_OPENSSL`. The separate `--owned-null-contexts` flag
is a diagnostic decoded-media attempt with the limits above. No successful
full-flow result is currently recorded.

Original issues #125/#126/#128/#129/#130 remain open from this work. Optional
TLS control and incoming native media extend evidence; they do not establish
supported shipping restricted-network media, return/rejoin/A/V behavior,
Safari/mobile coverage, oldest-OS/Intel execution or larger measured capacity.
