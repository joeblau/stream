# Hosted owned scene LaunchServices protocol

This is source preparation for one future hosted component experiment. The
LaunchServices protocol described here has **not been executed**. It does not
establish keyboard delivery, explain the earlier activation result, or complete
#90 or #155.

## Preserved result and proposed boundary

The first hosted keyboard-setup attempt at `e597907ce1c9238aa4f5872cfc317941485bbccd`,
run [39889238145](https://github.com/joeblau/stream/actions/runs/39889238145),
returned native exit 77. Genuine stock/AppKit and production scene AX checks
passed. The single in-app activation request did not establish an active app
and key owned window within two seconds. Stock keyboard calibration and the
production key sequence were never reached. That first outcome and the earlier
local outcomes remain unchanged; see [the retained keyboard-setup report](HOSTED_SCENE_KEYBOARD_SETUP.md).

That hosted runner executed the Mach-O directly inside its owned `.app`.
The proposed comparison instead calls public
[`NSWorkspace.openApplication(at:configuration:completionHandler:)`](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))
with the exact fresh app URL. `activates=true` requests foreground launch. This
is a different application bootstrap transaction, not evidence that active/key
state or AX availability will improve. The earlier local macOS 27 beta
LaunchServices observation lost AX availability and remains a separate warning
about this hypothesis, not a result on hosted macOS 26.

The unsandboxed owned launcher requests a new instance, refuses running-app
substitution, disables prompts and recent-item insertion, and leaves hiding of
this app and other apps disabled. It targets no other application. The existing
single `NSApp.activate()` and two-second eligibility observation remain inside
the unchanged oracle; the LaunchServices activation request is recorded as an
additional bootstrap operation, not silently counted as the same request.

## Identity and native outcome

The opt-in runner mode is `--owned-launchservices`, together with the existing
owned-bundle, public own-parent C AX and owned-keyboard-setup modes. Original
direct execution remains available and receives no LaunchServices fallback.
The launcher forwards the actual existing hosted guards and required nonsecret
artifact values explicitly. It must not manufacture `GITHUB_ACTIONS` or
`RUNNER_ENVIRONMENT`, infer environment inheritance, or weaken the app's exact
bundle/hosted-mode checks. Apple's
[`environment` contract](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/environment)
does not supply this forwarding for sandboxed callers; this unsandboxed
component proposal does not qualify the sandbox chooser workflow in #155.

Each attempt has a fresh owned directory and nonce. Before the oracle runs, the
app atomically writes a schema-1 ready receipt containing the nonce, actual PID,
canonical resolved bundle and executable URL strings, source digest and actual
own-executable SHA-256, together with the original absolute deadline string and
the canonical owned runtime-log URL, and `phase="ready"`. Runtime logging uses
that owned artifact directly rather than assuming LaunchServices inherits the
launcher's stdout/stderr.
The source digest binds the original five runner input
snapshots: SHA-256 of the UTF-8 compact JSON map from relative source path to
snapshot SHA-256, with sorted keys and no separator whitespace. The app carries
that supplied digest as an opaque binding; the runner independently hashes the
snapshots. The launch helper is additionally snapshotted and hashed separately.

The launcher compares the receipt with the exact `NSRunningApplication` returned
by the launch completion, its PID/bundle/executable identity, and the prepared
binary/source bindings. It arms the owned native-exit observer before writing
a matching schema-1 ACK with `phase="ack"`, `monitorArmed=true` and no oracle
exit-code field. The app's bounded ready/ACK wait yields
its run loop, performs no UI action, and refuses a missing or mismatched ACK
within two seconds. It then invokes the original oracle. An atomic terminal
receipt records the same identity, `phase="oracle"` and actual oracle return
code immediately before `exit(code)`. Pre-oracle refusals use `phase="bootstrap"`;
expiry uses `phase="deadline"`. Neither can qualify an oracle result. A terminal
write failure returns 77. Existing phase artifacts retain the oracle's actual
reached setup/key boundary.

The helper separately observes the owned PID through public `EVFILT_PROC`
`NOTE_EXIT | NOTE_EXITSTATUS` and records registration errors, event flags, raw
wait status and its normal-exit/signal interpretation. This proposed non-child
status boundary must first be checked by owned non-UI exit controls; an app-side
intended return code cannot substitute for native exit status. Missing status,
an observation race, a mismatched receipt or a crash cannot pass. The binary hash
and source digest identify artifacts; they do not themselves prove execution.

Success requires actual native normal exit zero, matching atomic terminal
oracle zero and identity receipts, the returned owned application's observed
termination, and no deadline, monitor or cleanup error. A launch callback,
`open` helper exit zero, a PASS log line, a marker alone or a successful
`terminate()` request cannot establish that result. Native 77 remains
unqualified; a qualified production-oracle failure remains a failure.

## Deadline, cleanup and unchanged oracles

One monotonic 30-second runtime decision deadline starts before the launch
request and includes bootstrap, the original oracle, exit observation and
cleanup. The runner establishes the original 30-second absolute deadline and
a 27-second helper deadline at the same runtime entry, forwarding both as
uptime-nanosecond values. The helper reserves its last two seconds for cleanup;
the runner's owned-helper termination/reaping remains inside the original
30 seconds. Callback delivery and handshake completion do not restart either
deadline. The app receives the original deadline to refuse an expired late
start. This cross-process comparison requires macOS, Python 3.10 or newer and
the runner's recorded `mach_absolute_time` monotonic-clock implementation;
the Swift side uses the corresponding public uptime-nanosecond clock. These
clock bindings are preparation, not a measured calibration result.
The launcher's main run loop remains
able to advance, including while observing the time-varying
[`NSRunningApplication` properties](https://developer.apple.com/documentation/appkit/nsrunningapplication).
The implementation must retain ownership of a late returned application,
refuse late success and record actual termination or incomplete cleanup. It may
request termination only of that exact verified owned instance; it must not
signal a LaunchServices-inherited process group or scan unrelated applications.
Timeout and forced cleanup are nonpassing even if an earlier terminal receipt
claimed zero. Original compiler limits remain unchanged.

The genuine AX baselines, observed owned active/key state, actual stock focus
without setup callbacks, stock Space → Tab → Space calibration and subsequent
production focus and `[1, 2]` callback oracle remain unchanged. There is no focus
reset between Tab and Space, synthesized semantic tree, trust prompt, preference
change, global HID, forced activation, private API or other-app observer. An
unavailable precondition returns 77 rather than diagnosing a control defect or
lock state. Once genuine stock delivery and production initial focus qualify,
a failed production oracle remains a failure.

The first hosted outcome must retain source/helper snapshots and hashes,
compiler inputs/logs, app metadata and binary hash, nonce/ready/ACK/terminal
receipts, launch result, native exit observation, phase facts, cleanup state and
runtime status, including on failure. It ends this one comparison: no automatic
retry, direct-exec fallback or alternate observer follows. Source preparation
and protocol review are not runtime evidence. Until that exact result exists,
LaunchServices success and the original keyboard criterion remain unqualified.
