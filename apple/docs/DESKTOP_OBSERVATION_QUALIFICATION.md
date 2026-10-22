# Initial session and last-display recovery observations

Issue #158's lifecycle policy also applies when a runtime is constructed after
the lock event, and when the last active display disappears. The coordinator
now samples the current WindowServer session after registering its observers.
A locked, inactive, missing or unreadable session starts with the existing
public-output gate closed and a visible manual-resume notice. Initialization
does not invoke any output, preview or capture action. Unlock retains the
existing manual output-restart requirement; only a previously opted-in wake
preview can resume automatically.

The read-only adapter uses the public
[CGSessionCopyCurrentDictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary())
and documented console/login-complete keys. The supplemental
`CGSSessionScreenIsLocked` dictionary marker is not a documented standard
session property. When present, it prevents an already-locked console session
from being mistaken for unlocked. macOS normally omits this optional marker
when unlocked, so a completed active console session without it remains usable.
Absent GUI/session flags and malformed marker values are conservative failures.
This supplemental observation is a compatibility limitation, not a claim that
the standard console flag alone proves screen unlock. The existing lock/unlock
notifications continue updating the coordinator after initialization.

Display enumeration distinguishes failure (`nil`) from a successful empty set.
An empty set is published to the existing capture-pool callback, which can
retire pinned display captures; returning the same display ID then publishes a
fresh recovery callback. Failed enumeration preserves the last known set,
and equal successful sets do not repeat recovery.

Run the focused source fixture without a whole-app build:

```sh
zsh apple/scripts/run_resilience_observation_harness.zsh
```

The fixture compiles the actual resilience model, coordinator and device
monitor directly with Swift 6 strict concurrency and two compiler jobs. It
injects only session observations and the `CGGetActiveDisplayList` read boundary;
no production source is rewritten. It checks initial locked/unavailable and
normal unlocked sessions, missing/malformed session properties, locked wake
deferral, idempotent unlock, manual output restart, successful zero-display
enumeration, `[A] -> [] -> [A]`, failed enumeration, equal sets and preservation
of an independently remaining display. It also creates a production-default
coordinator and checks its actual current host observation.

Local qualification: Mac15,8, macOS 27.2 (26B118), Xcode 27.2 (27B5038j).
Both fixture groups pass. The actual host reports the supplemental locked
marker, and the production-default coordinator starts with `isLocked=true`.
The fixture changes no session, display, permission or output state, discovers
no camera/microphone, and requests no new grants. Controlled topology results
qualify the software boundary rather than physical cable/OS event delivery.
