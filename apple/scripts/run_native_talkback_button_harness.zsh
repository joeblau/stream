#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly BUTTON_DIR="build/native-talkback-button-validation"
mkdir -p "$BUTTON_DIR"
# Compile the exact shipping Cocoa hold control without initializing runtime,
# credentials, capture devices, permissions or any provider graph.
ruby - "$BUTTON_DIR" <<'RUBY'
folder=ARGV[0]
source=File.read('StreamMac/NativeGuestTalkbackView.swift')
marker='private struct NativeTalkbackHoldButton: NSViewRepresentable {'
abort 'Shipping hold control boundary changed' unless source.scan(marker).length==1
control=source[source.index(marker)..]
File.write(File.join(folder,'HoldValidation.swift'), "import AppKit\nimport SwiftUI\n"+control+File.read('scripts/native_talkback_button_harness.swift'))
RUBY
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI "$BUTTON_DIR/HoldValidation.swift" -o "$BUTTON_DIR/HoldValidation"
python3 - "$BUTTON_DIR/HoldValidation" <<'PY'
import subprocess,sys
try: raise SystemExit(subprocess.run(sys.argv[1:],timeout=20).returncode)
except subprocess.TimeoutExpired: raise SystemExit('FAIL: owned hold control exceeded its twenty-second cleanup bound')
PY
