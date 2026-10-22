#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly FOCUS_VALIDATION_DIR="${FOCUS_VALIDATION_DIR:-build/studio-focus-restoration-validation}"
mkdir -p "$FOCUS_VALIDATION_DIR"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -j2 \
    StreamMac/StudioFocusRestoration.swift scripts/studio_focus_restoration_harness.swift \
    -o "$FOCUS_VALIDATION_DIR/StudioFocusRestorationHarness"
python3 - "$FOCUS_VALIDATION_DIR/StudioFocusRestorationHarness" "$@" <<'PY'
import subprocess,sys
try:
    raise SystemExit(subprocess.run(sys.argv[1:], timeout=15).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned native focus ownership fixture exceeded15-second bound',flush=True)
    raise SystemExit(1)
PY
