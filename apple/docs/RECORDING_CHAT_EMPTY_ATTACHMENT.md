# Empty recording-chat attachment fast path

`RecordingChatPaint.attach` now checks whether its raw input is empty before
constructing a JSON encoder and encoding an array that would be discarded.
This removes concrete work from frames with no chat paint. It does not establish
a measured speedup or qualify the original #92 sustained capacity requirement.

The complete production source, compiled directly with CoreMedia, CryptoKit and
Foundation, passed one owned baseline/fixed comparison. Two zero-sample
CMSampleBuffers verify that empty input leaves a blank sample blank and preserves
existing attachment bytes/mode. Valid optional fields, ordering and duplicates
survive; nonempty all-invalid input still overwrites prior paint with encoded
`[]`; valid filtering followed by the first 32 entries is unchanged. Both versions
produce the same result JSON. This proof starts no renderer, audio/device graph,
UI, network or StreamCore/App build.

The first fixture compile failed because a stored global CFString was not
Sendable under Swift 6. Its log and source hash are retained; the exact initial
fixture was reconstructed afterward by reversing the single key declaration
change and verifying that hash. The corrected fixture uses a computed CFString,
as production already does. Both corrected compile/runtime stages passed with
Swift 6 and the same checks; no compiler or assertion gate was relaxed.

The [dated receipt](RECORDING_CHAT_EMPTY_ATTACHMENT_2026-10-22.json) binds the
whole baseline/current sources, fixture/runner, executables and all retained
logs/results. Pixel/PTS/clock, output-bank bounds and recipient ownership are
unchanged. No image or real recording session is exercised by this narrow
attachment proof, and #92 remains open.
