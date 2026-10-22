#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly EXCLUSION_BUILD="${BROWSER_EXCLUSION_BUILD_DIR:-$PWD/build/browser-exclusion-validation}"
: "${BROWSER_EXCLUSION_CORE_PRODUCTS:?Set an immutable matching StreamCore framework products path}"
mkdir -p "$EXCLUSION_BUILD/frameworks"
if [[ ! -d "$EXCLUSION_BUILD/frameworks/StreamCore.framework" ]]; then
  cp -cR "$BROWSER_EXCLUSION_CORE_PRODUCTS/StreamCore.framework" "$EXCLUSION_BUILD/frameworks/"
fi
python3 - "$EXCLUSION_BUILD/ProductionIdentities.swift" <<'PY'
import pathlib,re,sys
def decl(path,name):
 m=list(re.finditer(r'(?ms)^(?:struct|enum) '+re.escape(name)+r'\b[^\n]*\{.*?^}',pathlib.Path(path).read_text()))
 if len(m)!=1:raise SystemExit('Production identity boundary changed: '+name)
 return m[0].group(0)
graph='StreamMac/LayerGraph.swift'
names=['GraphID','CameraSourcePayload','ScreenSourcePayload','CaptureRegion','ScreenZoomOptions','ActiveAppTrackingOptions',
 'CapturePrivacyOptions','EffectiveCapturePrivacy','WebSourcePayload','SyphonSourcePayload','AppAudioSourcePayload']
text='import Foundation\nimport StreamCore\n'+'\n'.join(decl(graph,n) for n in names)
for pat in [r'^enum SourceDefinitionTag \{\}$',r'^typealias SourceDefinitionID = .+$']:
 m=re.findall(pat,pathlib.Path(graph).read_text(),re.M)
 if len(m)!=1:raise SystemExit('Production ID declaration changed')
 text+='\n'+m[0]+'\n'
m=re.findall(r'(?ms)^extension ScreenSourcePayload \{\n    /// Resolves.*?^}',pathlib.Path(graph).read_text())
if len(m)!=1:raise SystemExit('Production privacy extension changed')
text+='\n'+m[0]+'\n'+decl('StreamMac/CaptureSourcePool.swift','CaptureSourceKey')+'\n'
pathlib.Path(sys.argv[1]).write_text(text)
PY
# Generated same-file accessor calls the production mix operation without starting
# its autonomous clock, taps, devices or output graph. No shipping accessor added.
cp StreamMac/AudioMixEngine.swift "$EXCLUSION_BUILD/FixtureAudioMixEngine.swift"
cat >> "$EXCLUSION_BUILD/FixtureAudioMixEngine.swift" <<'SWIFT'
extension AudioMixEngine {
    func exclusionFixtureProgram(_ id: AudioChannelID, at position: Int64 = 0) -> [Float] {
        var program = [Float](repeating: 0, count: 1024), aux = program, isolated = program
        var pre = program, monitor = program, contribution = program
        _ = registry.mixChannel(id, at: position, frameCount: 512, program: &program, aux: &aux,
            isolated: &isolated, preEffects: &pre, monitor: &monitor, contribution: &contribution, soloActive: false)
        return program
    }
}
SWIFT
xcrun swiftc -swift-version 6 -j2 -strict-concurrency=complete -parse-as-library \
  -module-cache-path "$EXCLUSION_BUILD/module-cache" -F "$EXCLUSION_BUILD/frameworks" -framework StreamCore \
  "$EXCLUSION_BUILD/ProductionIdentities.swift" \
  StreamMac/BrowserCaptureExclusions.swift StreamMac/BrowserWidgetAudioProtocol.swift StreamMac/BrowserWidgetLocalContent.swift StreamMac/BrowserWidgetVisualProtocol.swift \
  StreamMac/AppAudioCapture.swift StreamMac/ScreenSourceCapture.swift StreamMac/ScreenRegionDynamics.swift \
  StreamMac/GuestMediaReceipts.swift StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift \
  StreamMac/RecordingChatPaint.swift StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift \
  StreamMac/RawVideoResourceCoordinator.swift StreamMac/FrameDeliveryBroker.swift StreamMac/FrameDeliveryConverter.swift StreamMac/RecordingFrameDelivery.swift \
  StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift "$EXCLUSION_BUILD/FixtureAudioMixEngine.swift" \
  scripts/browser_exclusion_harness.swift -o "$EXCLUSION_BUILD/harness"
# No NSApplication, SCK, helper, audio device, mixer clock, publisher or capture starts.
env DYLD_FRAMEWORK_PATH="$EXCLUSION_BUILD/frameworks" python3 - "$EXCLUSION_BUILD/harness" <<'PYRUN'
import subprocess,sys
try:
    raise SystemExit(subprocess.run(sys.argv[1:],timeout=30).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: owned no-capture exclusion fixture exceeded30seconds',flush=True)
    raise SystemExit(1)
PYRUN
python3 - "$EXCLUSION_BUILD" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
names=['StreamMac/BrowserCaptureExclusions.swift','StreamMac/AppAudioCapture.swift','StreamMac/ScreenSourceCapture.swift',
'StreamMac/ScreenRegionDynamics.swift','StreamMac/BrowserWidgetAudioProtocol.swift','StreamMac/BrowserWidgetLocalContent.swift','StreamMac/BrowserWidgetVisualProtocol.swift',
'StreamMac/GuestMediaReceipts.swift','StreamMac/IsolatedRecordingTypes.swift','StreamMac/IsolatedVideoTypes.swift',
'StreamMac/RecordingChatPaint.swift','StreamMac/RecordingChatTypes.swift','StreamMac/RecordingChatArchive.swift','StreamMac/RecordingChatReader.swift',
'StreamMac/RecordingPreferences.swift','StreamMac/RawVideoResourceCoordinator.swift','StreamMac/FrameDeliveryBroker.swift',
'StreamMac/FrameDeliveryConverter.swift','StreamMac/RecordingFrameDelivery.swift','StreamMac/ProgramRecordingSession.swift','StreamMac/AudioMixEngine.swift',
'scripts/browser_exclusion_harness.swift']
r={'scope':'Controlled no-capture transactions and actual mixer ingestion/reset; no mixer clock/device/UI/helper. Pool and session context are not compiled or executed by this focused target.',
'compiledSourceSHA256':{n:hashlib.sha256(pathlib.Path(n).read_bytes()).hexdigest() for n in names},
'integrationContextSHA256':{n:hashlib.sha256(pathlib.Path(n).read_bytes()).hexdigest() for n in
 ['StreamMac/CaptureSourcePool.swift','StreamMac/BrowserWidgetHelperSession.swift']},
'generatedSourceSHA256':{n:hashlib.sha256((p/n).read_bytes()).hexdigest() for n in ['ProductionIdentities.swift','FixtureAudioMixEngine.swift']},
'frameworkSHA256':hashlib.sha256((p/'frameworks/StreamCore.framework/StreamCore').read_bytes()).hexdigest(),
'harnessSHA256':hashlib.sha256((p/'harness').read_bytes()).hexdigest()}
(p/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
PY
