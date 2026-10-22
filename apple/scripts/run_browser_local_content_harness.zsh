#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly LOCAL_CONTENT_BUILD="${BROWSER_LOCAL_CONTENT_BUILD:-$PWD/build/browser-local-content-validation}"
mkdir -p "$LOCAL_CONTENT_BUILD"
xcrun swiftc -swift-version 6 -j2 -strict-concurrency=complete -parse-as-library \
  StreamMac/BrowserWidgetLocalContent.swift StreamMac/BrowserWidgetAudioProtocol.swift \
  StreamMac/BrowserWidgetVisualProtocol.swift scripts/browser_local_content_harness.swift \
  -o "$LOCAL_CONTENT_BUILD/harness"
python3 - "$LOCAL_CONTENT_BUILD/harness" <<'PY'
import subprocess, sys
raise SystemExit(subprocess.run(sys.argv[1:], timeout=30).returncode)
PY
