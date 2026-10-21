#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ALPHA_DIR="${BROWSER_ALPHA_BUILD_PATH:-build/browser-snapshot-alpha-validation}"
mkdir -p "$ALPHA_DIR"
# The candidate changes only public NSView opacity/backing-layer behavior in a
# generated copy. The shipping helper remains untouched when it is ineffective.
python3 - "$ALPHA_DIR" <<'PY'
from pathlib import Path
import sys
source = Path('BrowserAudioHelper/BrowserAudioHelperMain.swift').read_text()
needle = 'let view = WKWebView(frame:'
assert source.count(needle) == 1, 'Helper view construction boundary changed'
source = source.replace(needle, 'let view = BrowserAlphaPublicView(frame:', 1)
needle = '            view.underPageBackgroundColor = .clear'
assert source.count(needle) == 1, 'Helper transparency boundary changed'
source = source.replace(needle, needle + '\n            view.wantsLayer = true; view.layer?.isOpaque = false; view.layer?.backgroundColor = NSColor.clear.cgColor', 1)
source += '\n@MainActor private final class BrowserAlphaPublicView: WKWebView { override var isOpaque: Bool { false } }\n'
Path(sys.argv[1], 'PublicOpacityCandidate.swift').write_text(source)
PY
readonly SHARED=(StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetAudioSocket.swift StreamMac/BrowserWidgetVisualProtocol.swift)
swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library -O \
  "${SHARED[@]}" BrowserAudioHelper/BrowserAudioHelperMain.swift -o "$ALPHA_DIR/helper-baseline"
swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -parse-as-library -O \
  "${SHARED[@]}" "$ALPHA_DIR/PublicOpacityCandidate.swift" -o "$ALPHA_DIR/helper-public-opacity"
swiftc -swift-version 6 -parse-as-library \
  "${SHARED[@]}" scripts/browser_snapshot_alpha_harness.swift -o "$ALPHA_DIR/BrowserSnapshotAlphaHarness"
# Executable launch here qualifies pixels only, never app-audio attribution.
# No app install, codesign operation, TCC request or system capture is performed.
python3 - "$ALPHA_DIR/BrowserSnapshotAlphaHarness" "${ALPHA_DIR:A}" <<'PY'
import subprocess,sys
try:
    raise SystemExit(subprocess.run(sys.argv[1:],timeout=60).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: public browser alpha fixture exceeded 60 seconds',flush=True)
    raise SystemExit(1)
PY
