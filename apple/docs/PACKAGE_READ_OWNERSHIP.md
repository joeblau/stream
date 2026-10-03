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
