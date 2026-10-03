# Persistent guest positions and layouts

Guests can be prepared before a room exists. Saved slots live in the project's
versioned scene document with a stable UUID, editable label, public display
name/title, optional public reconnect peer UUID and separate camera/screen
offline card settings. A slot creates two reusable source definitions. Layer
and mixer identities remain stable through Take, source loss and project reload.
The catalogue is capped at 16; this does not increase the qualified native
capacity of one admitted media peer.

In Guests, create/configure positions and choose a saved position for a waiting
guest before admitting it. A known public peer reuses its saved assignment;
otherwise an unused position or a new bounded position is used. Reusing an
older position for a different invite is an explicit lobby assignment. Active
leases cannot be moved by changing this preparation metadata. Project reload
restores positions and framing; room credentials, invitations, receive leases,
generations and Program/Monitor permission are never persisted or replayed.

Solo, host/guest side-by-side, four-position grid, host/guest PIP and
screen-plus-guests create ordinary editable scene layers. Each guest name/title
is a typed slot binding on an ordinary text payload, separate from its font,
style and transform. The text inspector can change the slot or name/title field,
or remove the binding to edit literal text. Guest roster names update metadata;
the operator edits titles. Nested scenes containing these captions remain
dynamic, and unavailable or backstage media paints its configured card instead
of exposing private camera/screen pixels. Cards may be disabled to expose the
underlying scene. Existing guest payloads without a stable slot UUID keep their
original paint-nothing fallback.

Run the software qualification with XcodeGen and Xcode 26.6:

```sh
GUEST_SLOTS_BUILD_PATH=/tmp/owned-guest-slots-derived \
  zsh apple/scripts/run_guest_slots_harness.zsh
```

The whole-source fixture uses the established generated validation boundaries:
owned settings/defaults and memory credentials, no capture requests or provider
traffic. It creates real project files, reloads a fresh store/controller,
registers generation-fenced synthetic decoded receipts through the shipping
controller, renders actual software Core Image pixels and encodes/decodes an
H.264 lifecycle movie. It checks all five template positions, independent
camera/screen identity, Preview/Program separation, editable Take, offline/source
loss, nested automatic name/title changes, stale lease rejection, stable reload
and portable import remapping. Artifacts are retained in
`apple/build/guest-slots-validation/artifacts-*`.

The existing actual local Worker manager fixture additionally checks a prepared
slot chosen in the lobby, acknowledged admission into that exact slot, unchanged
source IDs, real scene document reload, and generation-fenced host reconnect.
Its media host is controlled for this control proof; it does not qualify browser
or relay decoding. Desktop/mobile browser compatibility, restricted networks,
studio return feed, A/V synchronization and capacity beyond one native peer
remain separate #125–130 validation gates. #129 remains open until those required
external validations are qualified.

Local Xcode 26.6 qualification: `/tmp/stream-guest-slots-native-final.log` and
`/tmp/stream-guest-slots-manager-final.log`. The dedicated native guest workflow also
runs the slot fixture on ARM and Intel and retains its synthetic project/movie.
