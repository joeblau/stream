# Optional extension adapters (version 1)

Optional adapters cross an authenticated, versioned process boundary. A manifest is data: it contains identity, roles, capability grants, and resource descriptors. It contains no executable path and does not install callbacks into the compositor, mixer, encoder, or trusted app process.

## Manifest and engine resources

`StudioAdapterManifest` declares `schemaVersion`, a stable reverse-domain `id`, display name/vendor/version, `minimumHostProtocol`, roles, resources, and exactly one contract for each declared role. Host/contract versions are checked before registration. Resource descriptors use UUIDs plus an explicit show-profile scope, resource kind/name, and optional parent UUID. Names may change; IDs are retained. Descriptors address the shared engine's scene/layer/source/output/audio-channel model without embedding a vendor into the composition graph.

The current version defines three boundaries:

| Role | Versioned contract | Host support |
| --- | --- | --- |
| Control | `studio-ipc-jsonl` v1; explicit stable command-ID allowlist; authenticated local snapshots/subscriptions/commands | Implemented through [Local Control](LOCAL_CONTROL_IPC.md). |
| Source | `authenticated-surface-xpc` v1; registry source UUID; BGRA8 surfaces; dimensions/rate limits; host monotonic timestamps; queue of at most 3 frames | Reserved descriptor contract. Media ingress/IOSurface XPC transport is unavailable and registration rejects this role. |
| Output | `authenticated-packet-xpc` v1; output UUID; H.264/AAC encoded packets; host monotonic timestamps; packet/queue bounds | Reserved descriptor contract. Packet egress XPC transport is unavailable and registration rejects this role. |

The reserved media contracts define proposed data/clock/bounds semantics, not working adapters or proof of hardware/provider compatibility. A future transport must negotiate entitlements, process identity, media-format details, lifecycle, surface ownership, deadlines, and recovery before the host advertises support. Missing source frames must degrade to missing-source state; blocked output processes must never block engine/render callbacks. Arbitrary executable plugin loading remains outside the trusted render callback.

A functional control adapter uses a dedicated Local Control client, authenticates at loopback `127.0.0.1:32145`, and consumes the host's live resource/command catalog. Its manifest grants exact command IDs. An empty allowlist permits state inspection only. The host validates every command against the approved list and the shared dispatcher's current targets/availability. The manifest does not override normal Take, lock, output, or permission rules. Macro grants explicitly authorize that macro; the studio's macro definition and validation govern its steps.

## Register, enable, disable, remove

In the visible studio's Optional Adapters panel, import a bounded JSON manifest, review its name/vendor/version and requested commands, and select a dedicated paired client from Local Control. Registration starts **Disabled** and immediately drops an existing connection for that client. Enabling permits a fresh authenticated connection. Start the external process through its own documented install/launch flow; the studio does not execute a path supplied by an imported manifest.

The panel displays Disabled, Connected, Waiting for external adapter, Local Control disabled, listener failure, or Pairing revoked. The adapter's process/crash behavior follows the Local Control contract: disconnect clears its session; fresh connection authenticates and re-fetches state; production commands are never replayed. The app may stop/rebind its listener during show-profile changes, so adapters must tolerate that boundary.

Disable is reversible: it persists the access gate and immediately disconnects the client, including cancellation of any macro owned by that connection. Its Keychain token is retained. **Remove and Revoke** first persists a disabled registration, disconnects, revokes the credential, then removes the registration. If Keychain revocation fails, the disabled restriction remains. Removing a registration cannot accidentally upgrade a restricted adapter to an unrestricted generic paired controller.

Registry metadata lives in the machine-scoped `studio.adapters.v1.json`; it contains no tokens. Corrupt/future registry documents are preserved and fail closed for local controllers until repaired. Save failures leave the previous approved document in force. Manifest imports are capped at 256 KB, registrations at 16, resources at 1000, and explicit command grants at 1000. The local wire protocol retains its request/frame/rate/session/backpressure limits.

## Sample external process

[integrations/sample-adapter](../../integrations/sample-adapter/manifest.json) provides a first-party read-only manifest and Python 3 controller. Pair a dedicated client, register this manifest, then enable it. Run:

```sh
python3 integrations/sample-adapter/studio_status_adapter.py
```

Paste its pairing JSON as a single stdin line. Credentials never appear in argv or logs. The sample authenticates, subscribes, prints authoritative JSON snapshots, and exits on disconnect, unsupported protocol, disabled registration, or malformed response. It never sends a production command or retries an interrupted session. Restarting requires a fresh handshake. Python's standard library is the sample's only runtime dependency; it is an external process, not code loaded by the app. A production adapter should store credentials in its platform's secure storage and implement its own clear lifecycle UI.

## Runtime integration and checks

Keep one `StudioAdapterManager` for the active machine workspace, and bind it to each newly constructed `StudioLocalControlServer` before the listener starts. Embed `StudioAdapterPanel(manager:server:)` in the native window's Application settings or inspector. The server's optional authorization hook leaves ordinary paired clients unchanged; registered adapter clients receive their enabled state and exact command grants. Listener teardown and runtime reconstruction remain owned by the workspace.

`zsh apple/scripts/run_studio_local_control_harness.zsh` compiles the production adapter contract/manager and Network server with memory-backed test credentials. Actual loopback sockets verify disabled authentication, command grants, rejected unapproved commands, disconnect/re-enable with a fresh session and no replay, cancellation of an adapter-owned macro, safe failed revocation, successful removal, future registry preservation/fail-closed behavior, and the original authentication/rename/delete/malformed/revoke/macro cancellation cases. `python3 integrations/sample-adapter/test_adapter.py` exercises the actual external sample process against a loopback fixture, including state feedback, disconnect, incompatible/disabled responses, and secret-free failures.

Before release, verify the visible register/enable/disable/remove flow and Keychain errors in the signed app, and exercise process kill/relaunch, app restart, project changes, and sleep/wake. Media XPC transport qualification remains separate future work; this version does not advertise working source or output adapters.

The native Local Control fixture now launches the actual bundled Python sample as a separate process against the production Network/Security server. Its dedicated registration rejects disabled admission, receives initial and changed authoritative state after enabling, exits on disable without replay, authenticates afresh on deliberate process restart, and exits on removal/revocation. Credentials travel through a private stdin pipe; bounded stdout/stderr are checked for token leakage. The existing native tests still exercise stable resource rename/delete, command allowlists, macro cancellation, incompatible media roles, future registry preservation and Keychain failure behavior. These are actual process/protocol checks with a deterministic studio dispatcher; they do not qualify future media XPC transports or the signed visible UI.
