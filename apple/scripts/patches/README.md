# Owned desktop relay policy patch

`libdatachannel-0.24-relay-policy.patch` changes only the derived source build used by `repair_desktop_transport_archives.py --require-relay-policy`. It does not modify the vendored Swift package, package pins, global caches, or the iOS artifacts.

The exact upstream sources are:

- [libdatachannel 0.24.0](https://github.com/paullouisageneau/libdatachannel/tree/8c31097ea78f051e857d0aa1b2f6efb26cd12b7e), commit `8c31097ea78f051e857d0aa1b2f6efb26cd12b7e`.
- Its pinned [libjuice source](https://github.com/paullouisageneau/libjuice/tree/5948a4162d37bc213d6051b67ee2876ccc5a99a6), commit `5948a4162d37bc213d6051b67ee2876ccc5a99a6`.

Both modified upstream implementations are Mozilla Public License 2.0 sources. Their copyright/license headers remain intact in the patch; the build also copies upstream license notices into `TransportSourceBuild/<architecture>/licenses`. The reviewed patch SHA-256 is `cf0d043f85076741f5582ba371c8896b3878bbd15f771c572028213fce4b6893`.

At these pins, libdatachannel's `TransportPolicy::Relay` filters candidate announcements while libjuice still adds an undifferentiated direct local pair. Actual owned local TURN testing selected a native server-reflexive candidate despite the configured policy. The application adapter rejects that selection before readiness or accepted media.

The patch adds `juice_set_relay_only` without changing existing function signatures or public struct layouts. Libdatachannel applies it from the existing `Configuration::iceTransportPolicy` immediately after agent creation. Relay agents omit host/reflexive gathering and direct pairs, reject direct authenticated peer checks and application ingress/egress, and retain TURN allocation, permission, channel, indication and refresh handling. Pinned libjuice TURN is UDP: relay agents reject remote non-UDP pairs before creating entries or attempting TCP connections, including when ICE-TCP is enabled. A started agent cannot change this policy. `All` retains the upstream path.

The compiled C marker `stream_rtc_relay_policy_20261002_v1` identifies the implementation. A per-architecture receipt binds its presence to the exact source pins, patch digest and compiled archive slice digest. `--require-relay-policy` rebuilds a missing/stale/unverified archive or fails; an existing `rtcCreatePeerConnection` symbol alone is insufficient. The build links the actual marker and setter, then proves that disabling relay after gathering returns failure. On a matching host it executes that smoke binary. It also compiles `relay-policy-tcp-harness` for the owned TURN fixture: a real relay must be gathered, the controlled `All` case must connect to the loopback TCP listener, and `Relay` must leave that listener unconnected. The earlier patch failed this real boundary; the UDP-only guard passes it. Cross-architecture builds still need execution on that architecture.

The source checkout must differ from upstream by exactly this patch. Repairs stay under the caller's derived-data directory, preserve the other architecture's archive slice, and select the active Xcode compiler and SDK explicitly. The marker is a build provenance check; actual selected-pair and decoded-media tests remain required.
