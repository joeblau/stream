# Native guest routing progress

The native receiver is an isolated public-SDK prototype. Its
[transport and codec qualification](../NativeGuestReceivePrototype/README.md)
uses real libdatachannel peers, H.264 video and public AudioToolbox Opus decoding.
A separate Chrome fixture exercises the shipping guest page against that native
host. The receiver is not linked into the production app target, and the guest
manager remains unavailable while native session control and return routing are
unfinished.

The application has explicit runtime-owned video and audio admission boundaries:

- `GuestSourcePayload` persists a stable slot UUID and camera/screen role. Older
  payloads decode with no slot; unknown roles fail decoding. Peer IDs, connection
  generations, negotiation IDs and clock mappings never enter scene documents.
- Registration requires the complete slot, peer, negotiation and generation
  lease. One slot is supported. A second slot cannot replace it implicitly, and
  generation high-water marks reject stale callbacks after removal or replacement.
  Registration creates stable camera/screen sources and a mixer channel only
  after the audio engine accepts the lease and current saved mixer settings.
- Registration interrupted by removal, retirement or a changed mixer setting
  publishes no sources or routing grants. The command dispatcher reads current
  settings, so editing a saved guest gain, mute, solo or auxiliary send takes
  effect without first issuing a guest command.
- Camera and screen identities stay separate. Screen admission starts disabled;
  stopping a screen clears its pixels. A camera expires after 250 ms without a
  due frame; an enabled static screen retains its last due frame.
- Each video role retains at most six BGRA buffers and 24 MiB. Pixel area is
  bounded to 1280×720, with dimensions up to 1920 for portrait geometry. Overflow
  drops oldest frames and counts loss. These are memory bounds, not measured
  guest capacity.
- Renderer lookup uses the original mapped host PTS at each composition tick.
  It does not consume frames needed by an earlier Preview or ISO tick. Program
  needs a separate routing grant; Preview can show the backstage source. Nested
  guest scenes remain dynamic. Missing registered sources do not fall back to an
  unrelated camera.
- Registered audio accepts owned, finite stereo Float32 PCM at 48 kHz, at most
  120 ms per receipt, with the original mapped PTS and one shared clock mapping.
  Labels, taps and callbacks cannot register a channel. Program and Monitor
  permissions are independent; Program permission also gates auxiliary sends
  and both pre-effects and post-effects audio ISO taps. Revocation rechecks
  queued ISO delivery, replacing denied queued PCM with counted silence.
- Guest video ISO subscriptions pin the full lease. A rejoin cannot silently
  replace an existing recording's source. Raw subscriptions retain source
  geometry; processed subscriptions use the source's actual effects.
- Workspace replacement, failed replacement recovery, backup restore and
  termination permanently retire video and audio admission. Closing a window
  does not retire the live runtime.

## Reproducible checks

Resolve the pinned transport using the normal app project and run
`repair_desktop_transport_archives.py` for that build's derived-data directory.
Set `STREAM_GUEST_RTC_INCLUDE` to its libdatachannel include directory containing
`rtc/`, and `STREAM_GUEST_RTC_LIBRARY` to its repaired static archive. An optional
`STREAM_VENDOR_ROOT` selects a clean, pinned vendor checkout for generated builds.

```sh
apple/scripts/run_native_guest_receive_harness.zsh
apple/scripts/run_guest_frame_store_harness.zsh
apple/scripts/run_guest_audio_harness.zsh
apple/scripts/run_fractional_iso_audio_harness.zsh
apple/scripts/run_guest_renderer_harness.zsh
apple/scripts/run_guest_persisted_mixer_harness.zsh
apple/scripts/run_native_guest_program_iso_harness.zsh
apple/scripts/build_native_guest_host_cli.zsh
npm ci --prefix workers/interviews
NATIVE_GUEST_HOST="$PWD/apple/build/native-guest-receive/guest-host-cli" \
  node workers/interviews/test/browser/native-host-browser.mjs
```

The receiver checks real decoded pixels and PCM, codec timing, one sender-report
clock anchor, malformed transport boundaries and stopped-session rejection. The
store and renderer checks use actual CoreVideo buffers and software Core Image
pixels, including delayed lookup after a later Program tick. Mixer checks use
real PCM, recording files and held callbacks to exercise routing, saved settings,
stale admission and ISO revocation. The Program/ISO fixture feeds actual decoded
SDK media through the compositor, mixer and recorders and compares decoded file
cues and endpoints.

The generated controller, persisted-mixer and Program/ISO tools use
`guest_fixture_boundaries.rb` to replace credential access with an empty, no-op stub
and standard defaults/storage with temporary fixture locations. They retain the
shipping registration, rendering, mixing, persistence and recording code. These
substitutions apply only to generated qualification targets; the production app's
credential store, entitlements and embedded extension declarations remain intact.

The Native guest media workflow runs these checks on Apple Silicon and Intel,
retaining logs and recording artifacts. A queued workflow is not qualification.
Local codec, Chrome, renderer, mixer, persisted-settings and actual SDK
Program/ISO checks pass on macOS 27.0.1/M3 Max with Xcode 26.6. Two strengthened
transport repetitions on opposite sides of half a PCM sample preserve exact
live timestamps/bytes, every source frame at rounded nanosecond boundaries,
identical recorded starts/counts/ends and every decoded Float32 value. Five
controlled AAC regressions also preserve the original fractional PCM grid and
genuine whole-sample gaps. These local results do not establish hosted Intel
qualification before its workflow finishes.

Native interview UI, deployed TURN, real screen-picker/capture permissions,
mobile and restricted networks, guest returns, recipient-specific mix-minus,
private talkback, long calls, measured capacity and older supported systems
remain unqualified. Passing these fixtures does not close those acceptance tasks.
