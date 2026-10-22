# Local HTML in the browser helper

The existing Browser Source inspector now lists HTML-file and folder assets from
its current profile's Asset Library. Import an HTML file for a self-contained
page. To include relative CSS, scripts, images or media, deliberately link a
folder in the Asset Library and select it here; its entry point is `index.html`.
An individual file pick grants only that file, never its parent or siblings.
Missing/revoked assets fail with the existing relink path. No raw path or
bookmark becomes a persisted browser configuration; the source retains the
asset ID and normal Preview/Take/undo semantics.

For the helper backend, the host holds the resolved library security scope while
an off-main task copies the selected file/tree. The copy reads through pinned
file/directory descriptors (`openat`, `O_NOFOLLOW`), rejects symlinks, hardlinks
and nonregular objects, and bounds the tree to 256 entries, 16 directory levels
and 64 MiB. It never reads an inferred parent directory. Cancellation and a
superseding load claim cannot install a completed old copy.

Each copy occupies an unpredictable, private 0700 App Group lease directory;
regular files are 0600. Authenticated private IPC carries a typed session,
widget, generation, token and relative entry name, with no external URL,
bookmark or file bytes. The helper verifies the exact manifest and page lease
before constructing the page. Public `WKWebView.loadFileURL` grants only that
lease's `content` directory, not the App Group or another page. Main/subframe
file navigation cannot leave the lease, including resolved symlink/path
traversal. Existing HTTPS access remains available; no HTTP file server or
private WebKit API is introduced. The normal in-app backend also uses the exact
selected file/folder as its public WebKit read scope instead of implicitly
allowing an HTML file's parent.

The staged copy is immutable for one page generation. Reload creates a new copy
from the current library grant, and waits for the previous page's exact Stop
acknowledgment. Stop first suspends playback and unloads the old page; only that
acknowledged lease is deleted. Failure or disconnected/shutdown IPC does not
turn `terminate()` into an exit receipt: unacknowledged files remain quarantined
until the exact retained `NSRunningApplication` reports termination. Failed
removal retries. A replacement page or stale acknowledgment cannot remove a
sibling/replacement directory. Cleanup also pins the created directory's device,
inode, type and owner; a different incarnation at the same pathname is retained,
not deleted.

Admission is also persistent: a private, checked, locked App Group inventory
allows at most 16 outstanding lease directories, including old quarantines and
unknown entries left by an earlier host. A fresh host does not infer process
exit from a recycled PID, delete unknown files, or bypass this bound. If exit
cannot be proven after a host crash, the old directory remains counted and new
local loads eventually refuse safely. This conservative orphan policy trades
availability for preserving still-live readers and bounds application-created
staging to 16 × 64 MiB. It is not an automatic orphan recovery feature.

## Controlled evidence and remaining qualification

`run_browser_local_content_harness.zsh` executes the real file store against
owned temporary files: exact-file scope, explicit folder relative bytes,
manifest/widget/generation checks, traversal/foreign-file denial, rejected
symlink/hardlink/FIFO/oversize/count inputs, persisted multi-session admission,
cancellation, cleanup failure and retry. It does not load WebKit or decode the
copied media. `BrowserHelperLifecycleChecks` executes the actual session with an
inert capture/mixer/transport boundary: held Stop, fresh reload, stale receipt,
and shutdown retention until an explicit owned-process exit receipt. Existing
CI executes these cases before any `--qualify` opt-in; the file-store runner is
also in the browser CI step.

This implements the missing local-content software path. It does not qualify
sandboxed signed-helper launch/App Group/WebKit subresource reads, actual
same-page sound/pixels, Program/ISO/monitor media or A/V timing. No helper, UI,
SCK capture, audio device/output, permission, signing or system setting was
started or changed by these controlled tests. The production independent route
remains disabled (`productionRouteQualified = false`) and #124 stays open.

The [frozen source/log/binary receipt](BROWSER_WIDGET_LOCAL_CONTENT_2026-10-22.json)
binds the controlled checks, shipping-helper typecheck and whole-source build.
