#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${GUEST_INSTALLATION_CORE_PRODUCTS:?Set immutable matching full StreamCore products}"
readonly output="${GUEST_INSTALLATION_BUILD_PATH:-$PWD/build/guest-installation-fence-validation}"
readonly native="${GUEST_INSTALLATION_NATIVE_SOURCE_ROOT:-$PWD}"
mkdir -p "$output/sources" "$output/frameworks"
if [[ ! -d "$output/frameworks/StreamCore.framework" ]]; then
  cp -cR "$GUEST_INSTALLATION_CORE_PRODUCTS/StreamCore.framework" "$output/frameworks/"
fi
python3 - "$output" "$native" <<'PY'
import hashlib,json,pathlib,re,shutil,sys
output,native=map(pathlib.Path,sys.argv[1:]); root=pathlib.Path.cwd()
names=['GuestMediaReceipts','IsolatedRecordingTypes','IsolatedVideoTypes','RecordingChatPaint','RecordingChatTypes',
'RecordingChatArchive','RecordingChatReader','RecordingPreferences','ProgramRecordingSession','AudioMixEngine',
'GuestVideoFrameStore','NativeInterviewTypes','NativeGuestReturnVideoBudget','RawVideoResourceCoordinator',
'FrameDeliveryBroker','FrameDeliveryConverter','RecordingFrameDelivery',
'NativeGuestMediaSink','GuestReturnVideoResources']
origins={}
for name in names:
    base=native if name in ['NativeGuestMediaSink','GuestReturnVideoResources'] else root
    source=base/'StreamMac'/(name+'.swift'); target=output/'sources'/source.name
    shutil.copy2(source,target)
    origins[str(target)]={'origin':str(source),'sha256':hashlib.sha256(source.read_bytes()).hexdigest()}
# Exact production value declarations satisfy AudioChannelID identities without
# compiling/constructing the capture pool, screen picker, or capture owners.
slices=[]
def declaration(path,name):
    source=path.read_text()
    matches=list(re.finditer(r'(?ms)^(?:struct|enum) '+re.escape(name)+r'\b[^\n]*\{.*?^}',source))
    if len(matches)!=1:raise SystemExit('Production value declaration changed: '+name)
    value=matches[0].group(0)
    slices.append({'origin':str(path),'declaration':name,'sha256':hashlib.sha256(value.encode()).hexdigest()})
    return value
graph=root/'StreamMac/LayerGraph.swift'
names=['GraphID','CameraSourcePayload','ScreenSourcePayload','CaptureRegion','ScreenZoomOptions',
'ActiveAppTrackingOptions','CapturePrivacyOptions','EffectiveCapturePrivacy','WebSourcePayload','SyphonSourcePayload','AppAudioSourcePayload']
identities='import Foundation\nimport StreamCore\n'+'\n'.join(declaration(graph,n) for n in names)
for pattern in [r'^enum SourceDefinitionTag \{\}$',r'^typealias SourceDefinitionID = .+$']:
    matches=re.findall(pattern,graph.read_text(),re.M)
    if len(matches)!=1:raise SystemExit('Production source ID declaration changed')
    identities+='\n'+matches[0]+'\n'
matches=re.findall(r'(?ms)^extension ScreenSourcePayload \{\n    /// Resolves.*?^}',graph.read_text())
if len(matches)!=1:raise SystemExit('Production privacy value extension changed')
identities+='\n'+matches[0]+'\n'+declaration(root/'StreamMac/CaptureSourcePool.swift','CaptureSourceKey')+'\n'
target=output/'sources/ProductionIdentities.swift';target.write_text(identities)
origins[str(target)]={'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'exactProductionSlices':slices,
                     'fullGraphOriginSHA256':hashlib.sha256(graph.read_bytes()).hexdigest()}
fixed='guard retainReturnVideoToken(token, source: source.id) else { return false }'
sink=output/'sources/NativeGuestMediaSink.swift'; text=sink.read_text()
if text.count(fixed)!=1:raise SystemExit('Current fixed guest sink cleanup guard changed')
old=text.replace(fixed,'guard retainReturnVideoToken(token, source: source.id) else { await source.remove(token); return false }')
(output/'sources/NativeGuestMediaSink.old-guard.swift').write_text(old)
(output/'sources.json').write_text(json.dumps(origins,indent=2)+'\n')
PY
typeset -a dependencies
dependencies=("$output/sources/"*.swift)
dependencies=("${(@)dependencies:#*/NativeGuestMediaSink.old-guard.swift}")
readonly products="$output/frameworks"
if [[ "${1:-}" == --typecheck-only ]]; then
  xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" -F "$products" -framework StreamCore -typecheck \
    "${dependencies[@]}" scripts/guest_installation_fence_harness.swift
  exit 0
fi
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$products" -framework StreamCore \
  -Xlinker -rpath -Xlinker "${products:A}" "${dependencies[@]}" \
  scripts/guest_installation_fence_harness.swift -o "$output/GuestInstallationFenceHarness"
typeset -a negative
negative=("${(@)dependencies:#*/NativeGuestMediaSink.swift}" "$output/sources/NativeGuestMediaSink.old-guard.swift")
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$products" -framework StreamCore \
  -Xlinker -rpath -Xlinker "${products:A}" "${negative[@]}" \
  scripts/guest_installation_fence_harness.swift -o "$output/GuestInstallationFenceHarness.old-guard"
python3 - "$output" <<'PY'
import pathlib,subprocess,sys
output=pathlib.Path(sys.argv[1])
for suffix,expected in [('',0),('.old-guard',1)]:
    try:result=subprocess.run([str(output/('GuestInstallationFenceHarness'+suffix))],capture_output=True,text=True,timeout=45)
    except subprocess.TimeoutExpired:raise SystemExit('FAIL: actual sink fixture exceeded45seconds')
    text=result.stdout+result.stderr;(output/('runtime'+(suffix or '.fixed')+'.log')).write_text(text)
    print(text,end='')
    if result.returncode!=expected:raise SystemExit('FAIL: unexpected controlled fixture status '+str(result.returncode))
    if suffix and 'Late install ACK removed source before codec owner cleanup' not in text:raise SystemExit('FAIL: old-guard negative did not reach the intended fence assertion')
print('PASS: ONLY the old cleanup guard fails the unchanged actual-sink fence assertions')
PY
