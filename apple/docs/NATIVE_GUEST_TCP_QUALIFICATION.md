# Owned TCP TURN backend qualification

The subsequent [pinned macOS 14 build closure and relink result](NATIVE_GUEST_TCP_PORTABILITY.md)
removes the dependency floor limitation for separate optional ARM64/x86_64
artifacts. The current-host result below remains a distinct measured artifact.

The shipping libdatachannel 0.24.0 archive uses libjuice, whose public backend
supports TURN over UDP. ICE TCP candidates do not establish TURN-over-TCP
support. The default `GuestReceive.cpp` guard therefore continues to reject a
TCP-only or TLS-only TURN configuration.

This repository includes an explicitly enabled **qualification backend**, using
the same public libdatachannel API with its optional `USE_NICE` implementation.
It does not change the packaged SDK, release dependency graph, or supported
deployment floor. The qualification macro `STREAM_NATIVE_NICE_TURN_TCP` and a
compiled application-owned backend receipt must both be present before the
bridge accepts TCP TURN. An ordinary build accepts UDP only.

The patch sets libnice `force-relay` for the existing relay-only policy. Its
compiled transport receipt advertises UDP and TCP only. TLS remains disabled:
the pinned libnice RFC5245 socket construction does not wrap TURN TLS in a real
TLS stream (its pseudo-TLS wrappers are compatibility-specific). An enum called
`NICE_RELAY_TYPE_TURN_TLS` alone does not qualify encrypted TURN.

Sources: [libjuice limitations](https://github.com/paullouisageneau/libjuice),
[libdatachannel build options](https://github.com/paullouisageneau/libdatachannel/blob/v0.24.0/CMakeLists.txt),
[pinned libnice socket construction](https://github.com/libnice/libnice/blob/ae3eb16fd7d1237353bf64e899c612b8a63bca8a/agent/agent.c).

## Build and provenance

`apple/scripts/build_owned_nice_transport.py` clones exact SDK and libnice
revisions into a caller-owned build directory, applies the adjacent force-relay
patch, and builds with at most two jobs. It requires existing OpenSSL, GLib,
Meson and Ninja installations; it installs no global packages. The JSON receipt
records source/submodule pins, every merged archive digest, actual dependency
runtime floors, patch digest, remaining system linker flags and notices.

The reviewed host GLib 2.90.1 static archives require **macOS 27**. Requesting a
macOS 14 target with those archives fails the helper's floor check. A current-host
TCP demonstration does not qualify macOS 14, Intel, signing, distribution or
release adoption. The helper output is a local experiment; redistribution needs
the complete dependency source/license and relinking materials, reviewed under
each dependency's terms. Existing GLib installation receipts and notices are
preserved, but they do not establish a source-reproducible release dependency.

Example, with absolute existing prefixes and a separate build directory:

```sh
python3 apple/scripts/build_owned_nice_transport.py \
  --build-dir /absolute/owned/nice-transport \
  --openssl-prefix /absolute/owned/openssl \
  --glib-prefix /absolute/existing/glib \
  --tools-prefix /absolute/owned/meson-venv \
  --deployment-target 27.0
```

Use the resulting archive only in a copied qualification project/cache. Preserve
the original vendor SDK and build products. Define `STREAM_NATIVE_NICE_TURN_TCP`
for the bridge, and add the receipt's remaining system link flags. Do not enable
the macro in the shipping project.

## Actual media restriction fixture

The existing native return-video browser fixture accepts
`STREAM_INTERVIEW_RELAY_TRANSPORT=tcp` (default `udp`). Its owned Coturn listener
disables UDP in TCP mode, and both peers receive only a TCP TURN URL under a
relay-only ICE policy. The fixture checks Chrome's selected candidate
`relayProtocol`, the native selected local relay candidate, established native
TCP sockets to the sole TURN endpoint, and absence of a server UDP listener.
The relay allocation itself can correctly remain UDP; this is distinct from the
TCP client-to-TURN connection.

The actual production Manager, Dispatcher, default receiver, controller-issued
sink and audio mixer handle generated camera H264, independent screen H264,
Opus, private control, native stereo mix-minus return, selectable native H264
return, full-lease rejoin and removal. The CLI's frame receipts read current
lease pixels already admitted to the production controller store. Screen
approval goes through the Dispatcher; revocation must immediately clear screen
pixels while camera/audio continue, and replacement must not inherit approval.
The fixture uses a local Worker and synthetic captures, with no device permission
changes, system network changes, or deployed provider/broker operations.

```sh
DYLD_FRAMEWORK_PATH=/absolute/owned/derived/Build/Products/Debug \
NATIVE_INTERVIEW_RETURN_AUDIO_CLI=/absolute/owned/derived/Build/Products/Debug/NativeInterviewReturnAudioCLI \
STREAM_INTERVIEW_TURN_SERVER=/absolute/owned/coturn/bin/turnserver \
STREAM_INTERVIEW_RELAY_TRANSPORT=tcp \
node workers/interviews/test/browser/native-interview-return-video-browser.mjs --video-flow-only
```

## Recorded local result

On 2026-10-21, the full `--video-flow-only` invocation passed on macOS 27.2
(26B118), ARM64, Xcode 27.2 (27B5038j), Chrome 155.0.8059.85, from production
baseline `4d388ba` with the qualification changes above. Before and after actual
full-lease rejoin, Chrome selected `relayProtocol=tcp`, the native selected
candidate was a relay with an established TCP connection to the sole owned
endpoint, and the server had no UDP listener. Its UDP relay allocation was
reported separately and retained that label.

Decoded camera and independent screen pixels, approved/revoked screen lifecycle,
controlled chooser denial with same-lease recovery, independent stop/retry,
accepted Opus, native Program/Secondary/Clean return pixels, fragmented-access-
unit recovery, private messages and receipts, stereo return with own-signal
exclusion, mute/nonunity restore, fresh-lease return opt-in, stale command
rejection, removal, end and permanent cleanup all passed. All 28 guest client
tests also passed. The actual-media CLI SHA-256 was
`1a2ef8e26247f0501f2783fd1a110b2f3dbcb015fbf1bcbda1524f3148af721b`;
its optional backend archive SHA-256 was
`f6bd9d57b59b26053e8d5b8e322ddae3c75f55ec2dd8140ceaf3eee12e814407`.
The helper records each future rebuilt artifact independently; a different
artifact does not inherit this measured result.

The helper also completed a clean-patch rebuild and provenance emission with
all 13 merged archives checked at or below macOS 27.0 and 22 notice/provenance
files retained. Its explicit macOS 14 invocation refused the installed GLib 27
archives before building. A warm-cache libnice 27.2 archive was also caught by
the final floor check; Meson now reapplies explicit compiler/linker minimums
before reuse. The rebuilt archive is a separately recorded artifact, not a
substitution for the measured media CLI above.

`python3 apple/scripts/test_owned_nice_transport.py` checks staged top-level
source mutations and staged/unstaged recursive submodule mutations, including
when parent Git configuration hides dirty submodules. Every refusal preserves
the source working files and index; no SDK build or network is needed.

This result does not establish shipping restricted-network support. Internet
and mobile networks, TLS, deployed TURN, older runtimes, physical
capture/playout/AEC and signed installation remain separate acceptance
requirements. Issues #125, #126, #128, #129 and #130 retain their remaining
original criteria; this optional backend result alone cannot close them.
