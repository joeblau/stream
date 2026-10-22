#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SOCKET_DIR="${BROWSER_SOCKET_AUTHORITY_DIR:-build/browser-socket-authority}"
mkdir -p "$SOCKET_DIR"
swiftc -j2 -swift-version 6 -DSTREAM_NATIVE_VALIDATION -parse-as-library \
  StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetLocalContent.swift StreamMac/BrowserWidgetVisualProtocol.swift \
  StreamMac/BrowserWidgetAudioSocket.swift scripts/browser_socket_authority_harness.swift -o "$SOCKET_DIR/host"
cp "$SOCKET_DIR/host" "$SOCKET_DIR/peer"
cp "$SOCKET_DIR/host" "$SOCKET_DIR/other-peer"
codesign --force --sign - --identifier com.joeblau.StreamMac "$SOCKET_DIR/host"
codesign --force --sign - --identifier com.joeblau.StreamBrowserAudioHelper "$SOCKET_DIR/peer"
codesign --force --sign - --identifier com.joeblau.OwnedBrowserOtherPeer "$SOCKET_DIR/other-peer"
cp "$SOCKET_DIR/host" "$SOCKET_DIR/host.copy"
cp "$SOCKET_DIR/peer" "$SOCKET_DIR/peer.copy"
cp "$SOCKET_DIR/peer" "$SOCKET_DIR/peer.mutable"
python3 - "${SOCKET_DIR:A}" <<'PY'
from pathlib import Path
import subprocess,sys
folder=Path(sys.argv[1])
try:
    raise SystemExit(subprocess.run([str(folder/'host'),str(folder/'peer'),str(folder/'peer.copy'),str(folder/'other-peer')],timeout=35).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned socket authority fixture exceeded35seconds',flush=True)
    raise SystemExit(1)
PY
# Compile-time proof: shipping policy has no prototype case at all.
cat > "$SOCKET_DIR/ProductionPrototypeProbe.swift" <<'SWIFT'
func forbiddenPrototype(_ value: BrowserWidgetAudioSocket.Policy = .prototypeForQualification) {}
SWIFT
if swiftc -j2 -swift-version 6 -typecheck StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetLocalContent.swift \
  StreamMac/BrowserWidgetVisualProtocol.swift StreamMac/BrowserWidgetAudioSocket.swift \
  "$SOCKET_DIR/ProductionPrototypeProbe.swift" > "$SOCKET_DIR/production-prototype-rejected.log" 2>&1; then
  print 'FAIL: shipping policy accepted a validation-only prototype case'; exit 1
fi
python3 - "$SOCKET_DIR/production-prototype-rejected.log" <<'PY'
from pathlib import Path
import sys
assert "has no member 'prototypeForQualification'" in Path(sys.argv[1]).read_text()
print('PASS actual production compile rejects prototype policy; refusal log retained')
PY
if [[ "${BROWSER_SOCKET_HELPER_MODE_PROBES:-0}" == 1 ]]; then
  # No validation flag: exercise the actual shipped parser, not a generated variant.
  swiftc -j2 -swift-version 6 -parse-as-library \
    StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetLocalContent.swift StreamMac/BrowserWidgetVisualProtocol.swift \
    StreamMac/BrowserWidgetAudioSocket.swift StreamMac/BrowserWidgetRasterizer.swift \
    BrowserAudioHelper/BrowserAudioHelperMain.swift -o "$SOCKET_DIR/production-helper"
  python3 - "${SOCKET_DIR:A}/production-helper" <<'PY'
import os,subprocess,sys
modes=[[],['--ipc-mode','prototype'],['--ipc-mode','unknown'],['--ipc-mode','production'],
 ['--ipc-mode','production','--host-pid',str(os.getpid()),'--ipc-socket','/tmp/stream-owned-nonexistent-command','--frame-socket','/tmp/stream-owned-nonexistent-frame']]
for args in modes:
 result=subprocess.run([sys.argv[1],*args],input=b'{"action":"close"}\n',capture_output=True,timeout=5)
 assert result.returncode==0 and not result.stdout, (args,result.returncode,result.stdout)
 print('PASS production helper emitted no Ready/content for refused mode/authority:',args[:2],flush=True)
print('No positive provisioned sandbox/group or real capture is qualified by these refusals',flush=True)
PY
fi
