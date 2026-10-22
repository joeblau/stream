#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PUBLISHER_INGRESS_BUILD_PATH="${PUBLISHER_INGRESS_BUILD_PATH:-build/publisher-private-ingress-validation}"
mkdir -p "$PUBLISHER_INGRESS_BUILD_PATH"

# Compile real Core sources, or reuse explicit matching products. This fixture
# exercises owned generated pixels and inert Publisher actors only.
PUBLISHER_INGRESS_CORE_ARGUMENTS=()
if [[ -n "${STREAM_CORE_FRAMEWORK_DIR:-}" ]]; then
  [[ -d "$STREAM_CORE_FRAMEWORK_DIR/StreamCore.framework" ]] || { print -u2 'Set STREAM_CORE_FRAMEWORK_DIR to matching StreamCore products.'; exit 1; }
  PUBLISHER_INGRESS_CORE_ARGUMENTS=(-F "$STREAM_CORE_FRAMEWORK_DIR" -framework StreamCore -Xlinker -rpath -Xlinker "${STREAM_CORE_FRAMEWORK_DIR:A}")
else
  readonly PUBLISHER_INGRESS_CORE_DIR="${PUBLISHER_INGRESS_BUILD_PATH:A}/core"
  mkdir -p "$PUBLISHER_INGRESS_CORE_DIR"
  xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
    -target "$(uname -m)-apple-macos14.0" -module-name StreamCore StreamCore/*.swift \
    -emit-module-path "$PUBLISHER_INGRESS_CORE_DIR/StreamCore.swiftmodule" -o "$PUBLISHER_INGRESS_CORE_DIR/libStreamCore.dylib"
  PUBLISHER_INGRESS_CORE_ARGUMENTS=(-I "$PUBLISHER_INGRESS_CORE_DIR" -L "$PUBLISHER_INGRESS_CORE_DIR" -lStreamCore -Xlinker -rpath -Xlinker "$PUBLISHER_INGRESS_CORE_DIR")
fi

xcrun swiftc -j2 -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" "${PUBLISHER_INGRESS_CORE_ARGUMENTS[@]}" \
  StreamBroadcast/Publisher.swift StreamMac/SessionState.swift \
  StreamMac/RecordingChatPaint.swift StreamMac/RawVideoResourceCoordinator.swift \
  StreamMac/FrameDeliveryBroker.swift StreamMac/FrameDeliveryConverter.swift \
  StreamMac/DestinationVideoIngress.swift StreamMac/DestinationOutputController.swift \
  StreamMac/DestinationEncodedMailbox.swift StreamMac/DestinationSharedEncoder.swift \
  scripts/publisher_private_ingress_harness.swift \
  -o "$PUBLISHER_INGRESS_BUILD_PATH/publisher-private-ingress-harness"

# The fixture starts no child processes. subprocess.run retires and waits for
# its exact owned child on timeout; there is no reusable numeric group target.
python3 - "$PUBLISHER_INGRESS_BUILD_PATH/publisher-private-ingress-harness" <<'PY'
import subprocess, sys
try:
    raise SystemExit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned publisher private-ingress fixture exceeded 30 seconds', file=sys.stderr)
    raise SystemExit(124)
PY
