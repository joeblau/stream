#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly ROUTING_BUILD="${VIRTUAL_AUDIO_ROUTING_BUILD_DIR:-build/virtual-audio-routing-validation}"
mkdir -p "$ROUTING_BUILD"
# Exact production type declarations let this focused controller fixture avoid
# loading capture/guest/renderer runtimes. No alternate routing implementation.
python3 - "$ROUTING_BUILD/ProductionAudioIdentities.swift" <<'PY'
import pathlib, re, sys
def declaration(path, name):
    source = pathlib.Path(path).read_text()
    matches = list(re.finditer(r'(?ms)^(?:struct|enum) '+re.escape(name)+r'\b[^\n]*\{.*?^}', source))
    if len(matches) != 1:
        raise SystemExit('Expected exactly one production declaration: '+name)
    return matches[0].group(0)
graph = 'StreamMac/LayerGraph.swift'
names = ['GraphID', 'CameraSourcePayload', 'ScreenSourcePayload', 'CaptureRegion', 'ScreenZoomOptions',
         'ActiveAppTrackingOptions', 'CapturePrivacyOptions', 'WebSourcePayload', 'SyphonSourcePayload', 'AppAudioSourcePayload']
text = 'import Foundation\nimport StreamCore\n'
text += '\n'.join(declaration(graph, name) for name in names)
source = pathlib.Path(graph).read_text()
for pattern in [r'^enum SourceDefinitionTag \{\}$', r'^typealias SourceDefinitionID = .+$']:
    matches = re.findall(pattern, source, re.M)
    if len(matches) != 1: raise SystemExit('Production identity boundary changed')
    text += '\n'+matches[0]+'\n'
text += declaration('StreamMac/CaptureSourcePool.swift', 'CaptureSourceKey')+'\n'
text += declaration('StreamMac/AudioMixEngine.swift', 'AudioChannelID')+'\n'
pathlib.Path(sys.argv[1]).write_text(text)
PY
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
  -module-name StreamCore StreamCore/*.swift \
  -emit-module-path "$ROUTING_BUILD/StreamCore.swiftmodule" -o "$ROUTING_BUILD/libStreamCore.dylib"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -I "$ROUTING_BUILD" -L "$ROUTING_BUILD" -lStreamCore \
  -Xlinker -rpath -Xlinker "${ROUTING_BUILD:A}" \
  "$ROUTING_BUILD/ProductionAudioIdentities.swift" \
  StreamMac/MacAudioInput.swift StreamMac/AudioDeviceChannelMapper.swift \
  StreamMac/MonitorOutputDevices.swift StreamMac/MonitorOutput.swift \
  scripts/studio_virtual_audio_routing_harness.swift -o "$ROUTING_BUILD/harness"
"$ROUTING_BUILD/harness"
