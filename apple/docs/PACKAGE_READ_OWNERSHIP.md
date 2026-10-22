# Package preview and transfer ownership

Opening a new show package supersedes the previous preview request. Only the
latest request can change the preview, its error or busy state. Canceling the
preview closes that authority. Up to four actual reads may remain occupied;
supersession and cancellation do not remove a worker from this limit. A fifth
request reports an explicit error until an actual read returns. Obsolete
successes and failures cannot restore a canceled or newer preview.

Import and export each own an exclusive write token until their actual IO
returns. Native package delivery during either write reports an error and
retains the captured transfer source. Export owns the token before entering the
native save panel's nested run loop. Dismissing the preview or canceling the
calling task cannot release an import that is still copying. A successful import
remains staged as a separate show for explicit Apply.

All production IO still calls `ShowPackageIO` with the original Foundation URL,
including its existing security-scope and package validation behavior.
Containment validation constructs comparison paths from one normalized root.
This accepts existing `/tmp` and `/private/tmp` aliases without rewriting the scoped
root or returned URL. Traversal and real child symbolic links remain rejected.

## Reproducible qualification

```sh
STREAM_VENDOR_ROOT=/path/to/clean/apple/Vendor \
PACKAGE_READ_BUILD_PATH=/tmp/stream-package-reads-derived \
zsh apple/scripts/run_package_read_harness.zsh
```

The generated tool compiles the shipping Workspace and real desktop runtime.
It uses private defaults/catalog/recording directories, nil fixture credentials,
refused provider transport and microphone access, and the native validation
macro. It seeds an isolated profile to avoid legacy migration. No operator
credentials, device permissions, publishing or recording are exercised.

Only the IO completion boundary is held: each probe calls the real preview or
import before withholding its result. A second observer records completion of
the actual Workspace transaction. Tests prove that A finishing after B cannot
replace B, an old return cannot clear C's busy state, canceled noncooperative
workers retain all four occupied slots, and late malformed reads cannot publish
obsolete errors. An actual import retains its busy/source ownership across
native preview delivery, export requests, sheet dismissal and task cancellation;
the staged catalog and copied scene bytes are verified against the captured
package. The child is bounded to 45 seconds and all individual waits are bounded.

The macOS `PortableShowTests` suite separately verifies both existing temporary
root aliases, existing and missing children, unchanged returned URLs, actual
external and internal child symlink rejection, traversal rejection and changed
package bytes. The new alias test fails against the original production code
and passes with the consistent comparison. No extra security-scope grant is
introduced.

Synthetic input packages and the actual imported scene document remain under
`apple/build/package-read-validation/artifacts-*`. Temporary runtime persistence
and defaults are removed on process exit. This fixture qualifies IO ownership;
native sandbox/LaunchServices/bookmark evidence and the remaining chooser and
physical interaction gates are described separately in
[PORTABLE_SHOW_NATIVE_ENTRY.md](PORTABLE_SHOW_NATIVE_ENTRY.md).

## Package-only method qualification (2026-10-22)

The normal runner now recognizes the current manifest-bound import call and
forwards `previewedManifest` unchanged through its IO probe. A generation-only
regression rejects the old unbound call instead of silently dropping this
preview-to-import binding:

```sh
python3 apple/scripts/test_package_read_generation.py
```

For a run that does not construct the desktop runtime, use an already-built,
matching `StreamCore.framework` products directory:

```sh
PACKAGE_METHODS_CORE_PRODUCTS=/path/to/products \
zsh apple/scripts/run_package_read_methods_harness.zsh
```

This runner compiles the real package IO, scene models and migration, plus exact
production Workspace property/method slices. Its generated manifest records each
slice's source boundaries and SHA-256. Initialization only reads the seeded
catalog in the fresh owned fixture directory. The original export busy guard is
copied verbatim; reaching the following save-panel boundary traps. Thus this
qualifies rejection of export during an occupied import, not native panel use.

The generated harness preserves every package/race/import/catalog assertion and
the original bounded `NSCondition` completion holds. Its only omitted assertion
is the unrelated final runtime output predicate, replaced by the explicit line
`StudioRuntime/controller/recorder not constructed; their behavior not tested`.
The normal full-graph harness retains its real output predicate. No dummy runtime
or output state is supplied.

On the named local Apple Silicon host, the first purposeful package-only run
passed all five original ownership phases within the unchanged 45-second child
deadline. Real copied scene data and catalog retained the captured source across
cancelled import. The generation regression's three cases also passed. Source,
generated-slice, executable, immutable Core and retained log hashes are recorded
in [PACKAGE_READ_METHODS_2026-10-22.json](PACKAGE_READ_METHODS_2026-10-22.json).
This is not a full-runtime, keyboard chooser, sandbox, LaunchServices or UI
qualification; those original native acceptance requirements remain separate.
