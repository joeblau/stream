# Twitch title character limit

The supported title-update adapter now applies its 140-character local limit with Swift `String.count`, instead of limiting the UTF8 encoding to 140 bytes. A 140-character title made of the ordinary CJK character `界` contains 420 UTF8 bytes and previously failed locally before any PATCH.

Twitch's current [Modify Channel Information reference](https://dev.twitch.tv/docs/api/reference/#modify-channel-information) identifies a 140-character title limit in its 400-response reasons (reviewed 2026-10-22). Empty titles remain invalid. The adapter preserves the supplied text and sends only the title field for the selected broadcaster; it does not trim, normalize, truncate or silently change the title.

`String.count` counts extended grapheme clusters. The public reference does not define normalization or counting details for every Unicode sequence; these local tests do not claim universal provider acceptance of those sequences. Twitch retains authority over its response. Short precomposed/decomposed strings are checked byte-for-byte to prove that the adapter preserves their original representation.

Focused actual Core validation on 2026-10-22:

- Against the unchanged actual baseline framework, the exact new four-test fixture compiled and ran. Only the 140-CJK boundary failed with `ProviderFailure.invalidRequest`; the ASCII boundary, text-preservation and invalid-title controls passed. This expected negative is retained.
- After the one-line production change, a fresh framework built from all 76 actual Core sources and the same test bytes passed all four tests. Each accepted case asserts exactly one HTTPS PATCH, the exact broadcaster query, one JSON title field and unchanged title bytes. Empty and 141-character ASCII/CJK cases assert an invalid-request failure with zero requests.
- Both phases used strict Swift 6 and two compiler jobs, independent owned caches and bounded processes. Requests were intercepted by an injected in-memory `ProviderAPI` fixture. No HTTP transport, OAuth, provider account, credential store or broadcast was used. The full Core suite was not repeated in this focused validation.

Original commands, exact input manifests, logs and result bundles are retained under `apple/build/twitch-title-validation/`. This fixes local validation in an existing supported control; it does not qualify a live account or complete #133/#169.
