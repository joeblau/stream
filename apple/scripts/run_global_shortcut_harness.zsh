#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly GLOBAL_SHORTCUT_DIR="build/global-shortcut-validation"
mkdir -p "$GLOBAL_SHORTCUT_DIR"
swiftc -swift-version 6 -parse-as-library -framework AppKit -framework Carbon \
  StreamMac/StudioShortcutModel.swift StreamMac/StudioShortcutController.swift \
  scripts/global_shortcut_harness.swift -o "$GLOBAL_SHORTCUT_DIR/harness"
python3 - "$GLOBAL_SHORTCUT_DIR/harness" "$@" <<'PY'
import os,signal,subprocess,sys
process=subprocess.Popen(sys.argv[1:],start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=25))
except subprocess.TimeoutExpired:
    os.killpg(process.pid,signal.SIGTERM)
    process.wait(timeout=5)
    print('FAIL: owned global-shortcut qualification exceeded 25 seconds',flush=True)
    raise SystemExit(1)
PY
