#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${RAW_RESOURCE_CORE_PRODUCTS:?Set products containing the matching built StreamCore.framework}"
readonly products="${RAW_RESOURCE_CORE_PRODUCTS:A}"
readonly output="${RAW_RESOURCE_BUILD_PATH:-$PWD/build/raw-video-resource-validation}"
mkdir -p "$output"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -DSTREAM_NATIVE_VALIDATION \
  -parse-as-library -F "$products" -framework StreamCore \
  -Xlinker -rpath -Xlinker "$products" \
  StreamMac/RawVideoResourceCoordinator.swift scripts/raw_video_resource_harness.swift \
  -o "$output/RawVideoResourceHarness"
python3 - "$output/RawVideoResourceHarness" <<'PY'
import subprocess, sys
try:
    raise SystemExit(subprocess.run([sys.argv[1]], timeout=45).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned 16x16 resource lifecycle exceeded 45 seconds', flush=True)
    raise SystemExit(1)
PY
