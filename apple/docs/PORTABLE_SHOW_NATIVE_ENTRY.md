# Portable show native entry

A `.streamshow` opened through LaunchServices reaches the retained Workspace's
package preview. Import creates a separate project and stages it for explicit
Apply. Opening a file does not start capture, recording or publishing.

`StudioPackageOpenReceiver` receives this application's public `aevt/odoc`
open-document event. The observed shipping single-Window SwiftUI route closed
the only Studio window during native file delivery before its `onOpenURL`
callback ran. The receiver preserves that single window and passes the original
Foundation file URL to the existing preview/import code. Other `onOpenURL`
delivery remains wired independently. It binds weakly to the persistent
Workspace, retains at most eight early package URLs and rejects multiple
packages with a visible error. Non-file and non-package inputs are discarded.
Actual application termination releases the receiver and its early URLs.

## Native qualification

From the repository root, with a clean vendor checkout available:

```sh
STREAM_VENDOR_ROOT=/path/to/clean/apple/Vendor \
PORTABLE_NATIVE_BUILD_PATH=/tmp/stream-portable-native-derived \
zsh apple/scripts/run_portable_show_native_harness.zsh
```

The runner generates a unique fixture app from the shipping `@main` app, root
window, delegate and package receiver. Its defaults, credential storage,
provider transport, capture and permission boundaries are fixture-only. It
signs the owned app ad hoc and verifies exactly the App Sandbox, user-selected
read/write and app-scope bookmark entitlements. There are no network, device,
Keychain, App Group or debugging entitlements. It never changes default file
associations, TCC, system devices or another application's state.

The actual native checks cover:

- Reading an owned sibling file is denied before a native file grant.
- Hot and cold `NSWorkspace` open-file delivery reaches one preview and one
  Studio window; repeated delivery after a runtime switch uses the same current
  Workspace. Import remains an explicit command, delayed beyond event return.
- Actual shipping import/Apply retains copied LUT bytes, remaps scene and asset
  IDs, redacts credential/private endpoint/bookmark sentinels and preserves the
  transferred package bytes. Another import stages a distinct project.
- A real `NSItemProvider` file URL reaches the shipping drop/preview boundary.
- A native granted PNG repairs the imported missing linked asset through the
  shipping asset library, creates a real app-scope bookmark and remains readable
  after normal Quit and cold sandbox restart. Unrelated ungranted data remains
  denied on restart.
- Repeated non-package delivery and a native multi-package event preserve the
  current selection/window without implicit import.

The fixture only observes URLs at the shipping decoder; it installs no
substitute event handler and holds no additional package security-scope lease.
File identity assertions use the owned vnode identity to accommodate Foundation
spelling `/tmp` as `/private/tmp`; all production IO retains the original URL.
Artifacts and the unique fixture app container remain available after the run.
The runner copies bounded native receipts into its owned artifact directory;
runtime persistence and app-scope bookmark bytes remain in the unique container.
The child lifetime is bounded to 110 seconds, the parent to 100 seconds; native
receipts, file readiness and normal Quit have separate bounded waits.

## Limits

The real shipping `NSOpenPanel.runModal` is exercised using public local
`NSEvent` dispatch. On the qualified local host it returned cancellation; the
runner reports **UNQUALIFIED** and never substitutes a successful response or
selected URL. The native picker keyboard path needs manual qualification.
`NSItemProvider` delivery proves the typed drop boundary, not a physical pointer
sweep. Explicit `NSWorkspace` open-file delivery proves the LaunchServices path,
not physical Finder double-click. Physical missing-device repair, release
signing/notarization and other macOS versions remain separate qualification.

Local evidence uses macOS 27.0.1 on Apple Silicon and Xcode 26.6. The baseline
window-close trace is `/tmp/stream-portable-native-close-notification.log`; the
shipping receiver runs are `/tmp/stream-portable-native-shipping-receiver.log`
and `/tmp/stream-portable-native-shipping-complete.log` (the latter adds actual
repeated non-package and multi-package delivery checks).
The acceptance criteria in #155 remain subject to the explicit native picker
and physical interaction limits above.

The dedicated `Native show packages` workflow runs the signed sandbox fixture,
actual read/import ownership fixture and four portable Core tests on Apple
Silicon and Intel runners. Logs, synthetic package bytes, bounded native receipts,
exact entitlement declarations and Core test results are retained for 14 days.
A missing WindowServer or failed native delivery fails qualification; a canceled
chooser is reported as **UNQUALIFIED** and cannot establish picker acceptance.
The combined local branch passed the signed sandbox fixture after merging the
current native guest baseline and main; its final log is
`/tmp/stream-portable-native-final-artifacts.log` (Xcode 26.6, macOS 27.0.1, ARM).

## Frozen combined-source verification, 2026-10-21

The combined source at `703e8b9` was built and exercised again from an isolated
worktree on Mac15,8, macOS 27.2 (26B118), Xcode 27.2 (27B5038j), arm64. This
source includes the native intake/read-ownership changes together with the
recursive folder-media export, explicit unavailable-media errors, bounded
manifest/document reads, guest-title/public-chat preservation and actual signed
metadata audit changes from main.

The freshly built, ad hoc signed sandbox app passed hot/cold LaunchServices
intake, a real typed `NSItemProvider` drop, explicit import/Apply, distinct-show
conflict handling, scene/asset/LUT remapping and bytes, private sentinel
redaction, actual denied ungranted reads, granted linked-asset repair, normal
Quit/cold restart with the persisted app-scope bookmark, unchanged source
package bytes, repeated non-package delivery and multi-package rejection. The
exact three sandbox/file/bookmark entitlements and nested signature seal were
verified before launch. Eight PortableShow tests and three StudioProjects tests
also passed against these production sources; five distribution-audit fixture
tests passed separately. Signature metadata fixtures are not a notarized release.

The real shipping `NSOpenPanel` attempt again canceled/aborted and remained
**UNQUALIFIED**. Read-only session inspection reported
`CGSSessionScreenIsLocked = 1` with `loginwindow` foreground. Owned-process input
guards refused events into another foreground process; no unlock attempt or
permission change was made. Successful keyboard picker selection requires an
unlocked session. The physical Finder double-click, pointer drag and device
repair limits above remain explicit.

Fresh logs: `/tmp/stream-portable-final-build-20261021.log` and
`/tmp/stream-portable-final-native-20261021.log`. The run retained native receipts
and synthetic package bytes in
`build/portable-show-native-validation/artifacts-d7b88e40-0b39-4990-969a-54cb9fdba6f9`
of the isolated worktree. The unique owned app container and bookmark remain
available under the fixture bundle identifier printed in the native log.


## Package confirmation and drop intake, 2026-10-22

The shipping drop receiver now reads up to eight file-URL providers before
choosing a package. A non-package first item no longer hides a later package;
multiple packages produce the same one-package error as native open-file.
A newer file selection, chooser, import or canceled preview retires delayed
drop authority. Failed or incomplete providers produce a readable error.
Successful previews clear older intake errors, and scene names may repeat
without duplicate list identities. Import revalidates the package against the
manifest shown in its preview; changed packages require a new preview before
creating any project files or catalog entry.

The fresh `40d0737`-based native fixture passed these actual `NSItemProvider`
mixed/multiple/delayed delivery cases and changed-preview rejection, together
with hot/cold LaunchServices intake, explicit import/Apply, sandbox denial,
scoped missing-asset repair and cold restart. Log:
`/tmp/stream-wave2-projects-native-20261022.log`. These typed-provider checks do
not claim a Finder pointer gesture. The shipping native chooser was attempted
and canceled/aborted, so successful keyboard selection remains UNQUALIFIED.
No unlock, permission, default association or personal settings change was made.
