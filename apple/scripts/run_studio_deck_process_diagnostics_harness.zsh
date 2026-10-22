#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DIAGNOSTICS_DIR="${DECK_PROCESS_DIAGNOSTICS_DIR:-build/studio-deck-process-diagnostics-validation}"
mkdir -p "$DIAGNOSTICS_DIR"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  scripts/studio_deck_process_diagnostics.swift scripts/studio_deck_process_diagnostics_harness.swift \
  -o "$DIAGNOSTICS_DIR/harness"
python3 - "$DIAGNOSTICS_DIR/harness" "${DIAGNOSTICS_DIR:A}" <<'PYTHON'
import os,signal,subprocess,sys
process=subprocess.Popen(sys.argv[1:],start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=20))
except subprocess.TimeoutExpired:
    os.killpg(process.pid,signal.SIGKILL)
    process.wait()
    print('FAIL: owned process-diagnostics fixture exceeded20s; artifacts retained',flush=True)
    raise SystemExit(1)
PYTHON
