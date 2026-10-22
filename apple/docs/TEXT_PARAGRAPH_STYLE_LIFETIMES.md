# Core Text paragraph-style pointer lifetimes

`TextMeasurement.paragraphStyle` previously placed `&ctAlignment` and
`&lineBreakMode` in `CTParagraphStyleSetting` initializers, retained those
settings in an array, then called `CTParagraphStyleCreate`. The compiler reported
two `TemporaryPointers` diagnostics: each implicit pointer was valid only for its
initializer call, while the setting stores a raw pointer used by a later call.
The actual SDK's `CTParagraphStyle.h` declares that field as `const void *value`.
This was a pointer lifetime defect; no observed rendered corruption is claimed.

The helper now constructs both settings and creates the Core Text style inside
nested `withUnsafePointer` scopes. A nested `withUnsafeBufferPointer` supplies the
settings array for exactly the creation call. Both pointed-to values therefore
remain valid until Core Text has consumed them. Alignment mapping and the
existing wrapping/clipping/truncation policy are unchanged.

Run the small native check from the repository root:

```sh
zsh apple/scripts/run_text_paragraph_style_harness.zsh
```

It compiles the exact shipping `TextLayout.swift` using strict Swift 6, `-O` and
`-warnings-as-errors`. All three alignments, both wrapping choices and all three
overflow choices produce 18 actual Core Text styles. A non-inlined factory
returns before the fixture performs 256 bounded stack-pressure rounds and reads
both stored values using `CTParagraphStyleGetValueForSpecifier`. It checks the
expected enum values, not only style non-nullness or text dimensions. The
existing `TextLayoutTests` suite also exercises all 18 returned value pairs and
continues to cover measurement, font fallback and text models. This check creates
no capture graph, UI, network connection or system setting.

The optimized native check and freshly rebuilt `TextLayoutTests` passed on the
current ARM Mac. These are pointer/value and layout checks, not a GPU comparison,
physical-device qualification or a claim of previously visible corruption.

Swift contracts: [temporary pointer diagnostic](https://docs.swift.org/latest/documentation/diagnostics/temporary-pointers/)
and [implicit pointer conversion](https://docs.swift.org/swift-book/ReferenceManual/Expressions.html).
