#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PROGRAM_BUILD="${STUDIO_PROGRAM_BUILD_DIR:-$PWD/build/studio-program-producer-validation}"
mkdir -p "$PROGRAM_BUILD"
export CLANG_MODULE_CACHE_PATH="$PROGRAM_BUILD/clang-module-cache"
readonly PROGRAM_SDK="$(xcrun --sdk macosx --show-sdk-path)"
STREAM_VMIC_BUILD_DIR="$PROGRAM_BUILD/driver-build" zsh scripts/build_virtual_microphone_prototype.zsh
# Keep exact production scene/capture identity declarations while omitting
# unrelated live capture runtimes. AudioMixEngine itself is compiled whole.
python3 - "$PROGRAM_BUILD/ProductionIdentities.swift" <<'PY'
import pathlib, re, sys
def declaration(path, name):
    matches = list(re.finditer(r'(?ms)^(?:struct|enum) '+re.escape(name)+r'\b[^\n]*\{.*?^}', pathlib.Path(path).read_text()))
    if len(matches) != 1: raise SystemExit('Production identity changed: '+name)
    return matches[0].group(0)
graph='StreamMac/LayerGraph.swift'
names=['GraphID','CameraSourcePayload','ScreenSourcePayload','CaptureRegion','ScreenZoomOptions',
       'ActiveAppTrackingOptions','CapturePrivacyOptions','WebSourcePayload','SyphonSourcePayload','AppAudioSourcePayload']
text='import Foundation\nimport StreamCore\n'+'\n'.join(declaration(graph,name) for name in names)
for pattern in [r'^enum SourceDefinitionTag \{\}$',r'^typealias SourceDefinitionID = .+$']:
    matches=re.findall(pattern,pathlib.Path(graph).read_text(),re.M)
    if len(matches)!=1: raise SystemExit('Production identity boundary changed')
    text+='\n'+matches[0]+'\n'
text+=declaration('StreamMac/CaptureSourcePool.swift','CaptureSourceKey')+'\n'
pathlib.Path(sys.argv[1]).write_text(text)
PY
xcrun clang -std=c11 -fblocks -O2 -isysroot "$PROGRAM_SDK" -c \
  prototypes/VirtualMicrophone/StudioProgramRender.c -o "$PROGRAM_BUILD/StudioProgramRender.o"
xcrun clang -std=c11 -fblocks -O2 -isysroot "$PROGRAM_SDK" -c \
  scripts/studio_program_driver_fixture.c -o "$PROGRAM_BUILD/DriverFixture.o"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -emit-library -emit-module \
  -module-cache-path "$PROGRAM_BUILD/swift-module-cache" -module-name StreamCore StreamCore/*.swift \
  -emit-module-path "$PROGRAM_BUILD/StreamCore.swiftmodule" -o "$PROGRAM_BUILD/libStreamCore.dylib"
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -module-cache-path "$PROGRAM_BUILD/swift-module-cache" \
  -I "$PROGRAM_BUILD" -L "$PROGRAM_BUILD" -lStreamCore -Xlinker -rpath -Xlinker "$PROGRAM_BUILD" \
  -import-objc-header scripts/studio_program_driver_fixture.h \
  "$PROGRAM_BUILD/ProductionIdentities.swift" \
  StreamMac/GuestMediaReceipts.swift StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift \
  StreamMac/RecordingChatPaint.swift StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift \
  StreamMac/RawVideoResourceCoordinator.swift StreamMac/FrameDeliveryBroker.swift StreamMac/FrameDeliveryConverter.swift StreamMac/RecordingFrameDelivery.swift \
  StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift StreamMac/AudioMixEngine.swift \
  prototypes/VirtualMicrophone/StudioProgramProducer.swift scripts/studio_program_producer_harness.swift \
  "$PROGRAM_BUILD/StudioProgramRender.o" "$PROGRAM_BUILD/DriverFixture.o" \
  -framework CoreAudio -framework CoreFoundation -o "$PROGRAM_BUILD/harness"
readonly PROGRAM_ARTIFACTS="$PROGRAM_BUILD/artifacts-$(uuidgen | tr '[:upper:]' '[:lower:]')"
"$PROGRAM_BUILD/harness" "$PROGRAM_BUILD/driver-build/StreamVirtualMicrophone.driver/Contents/MacOS/StreamVirtualMicrophone" "$PROGRAM_ARTIFACTS"
python3 - "$PROGRAM_ARTIFACTS" "$PROGRAM_BUILD" <<'PY'
import hashlib,json,pathlib,platform,sys
artifacts,build=map(pathlib.Path,sys.argv[1:])
inputs=['StreamMac/AudioMixEngine.swift','StreamMac/RecordingChatPaint.swift',
        'StreamMac/RawVideoResourceCoordinator.swift','StreamMac/FrameDeliveryBroker.swift',
        'StreamMac/FrameDeliveryConverter.swift','StreamMac/RecordingFrameDelivery.swift','prototypes/VirtualMicrophone/StreamVirtualMicrophone.c',
        'prototypes/VirtualMicrophone/StreamLoopback.c','prototypes/VirtualMicrophone/StudioProgramProducer.swift',
        'prototypes/VirtualMicrophone/StudioProgramRender.c','prototypes/VirtualMicrophone/StudioProgramRender.h',
        'scripts/studio_program_driver_fixture.c','scripts/studio_program_driver_fixture.h',
        'scripts/studio_program_producer_harness.swift']
receipt={'executedArchitecture':platform.machine(),'sourceSHA256':{p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in inputs},
         'harnessSHA256':hashlib.sha256((build/'harness').read_bytes()).hexdigest(),
         'driverSHA256':hashlib.sha256((build/'driver-build/StreamVirtualMicrophone.driver/Contents/MacOS/StreamVirtualMicrophone').read_bytes()).hexdigest()}
(artifacts/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Owned artifacts:',artifacts)
PY
