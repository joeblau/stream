# Native guest routing progress

The native receiver is currently an isolated public-SDK prototype. Its
[transport and codec qualification](../NativeGuestReceivePrototype/README.md)
does not establish shipping interview UI, TURN, guest returns or ISO support.

The application now has an explicit runtime-owned video playout boundary:

- `GuestSourcePayload` persists a stable slot UUID and camera/screen role. Older
  payloads decode with no slot; unknown roles fail decoding. Peer IDs, connection
  generations, negotiation IDs and clock mappings do not enter scene documents.
- `GuestVideoFrameStore` accepts one explicitly registered slot. A second slot
  cannot replace it implicitly. Replacement of that slot clears frames and
  routing permission; stale receipts cannot register or repopulate it.
- Camera and screen identities stay separate. Screen admission is off by default
  and ending a screen clears its pixels. A camera expires after 250 ms without a
  due frame; an explicitly enabled static screen retains its last due frame.
- Each role retains at most six BGRA buffers and 24 MiB. Pixel area is bounded to
  1280×720, with dimensions up to1920 for portrait geometry. Overflow drops oldest
  frames and counts the loss. This is a memory bound, not a measured capacity claim.
- The renderer selects frames whose original mapped host PTS is due at its exact
  composition tick. It never displays the newest future buffer early. Program
  requires a separate routing grant; Preview can show the registered backstage
  source. Both use the same runtime store, and nested guest scenes remain dynamic.
- Workspace replacement, failed replacement recovery, backup restore and
  termination permanently retire the previous runtime's store. Window closure
  does not retire a live runtime.

The guest manager remains unavailable while native session control, registered
PCM, return routing and guest ISO integration are incomplete. The receiver is not
linked into the production app target yet. No automatic source or mixer channel
registration is claimed.

## Reproducible checks

```sh
apple/scripts/run_guest_frame_store_harness.zsh
STREAM_VENDOR_ROOT=/absolute/clean/Vendor \
  apple/scripts/run_guest_renderer_harness.zsh
```

The first check exercises the real store with generated CoreVideo receipts:
registration, due-frame selection, Program gate, exact identity, stopped-screen
and stale-camera behavior, bounded overflow, one shared mapping and retirement.
The second renders actual software Core Image pixels, including unchanged nested
scene models with changing guest frames, missing registered-source behavior and
backward-compatible payload persistence. Neither substitutes for receiver to
Program/ISO decoded flash-and-tone qualification.

On macOS27.0.1/M3 Max with Xcode26.6, both checks and the full unsigned production
app build pass. Production entitlements and embedded extension declarations are
preserved. Older supported systems, Intel receiver linking/runtime, actual capture,
deployed TURN, long calls and measured guest capacity remain unqualified.
