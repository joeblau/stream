#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_RETURN_BUILD_DIR:-${APPLE_DIR}/build/guest-return-audio-validation}
FRAMEWORKS=${STREAM_GUEST_RETURN_FRAMEWORKS:-${BUILD_DIR}/core-derived/Build/Products/Debug}
mkdir -p "${BUILD_DIR}"
if [[ ! -d "${FRAMEWORKS}/StreamCore.framework" ]]; then
  ruby -ryaml -rjson - "${APPLE_DIR}" "${BUILD_DIR}" <<'RUBY'
root,folder=ARGV
spec=YAML.load_file(File.join(root,'project.yml'))
spec['name']='GuestReturnAudioValidation';spec['packages']={}
spec['targets'].select!{|name,_|name=='StreamCore'}
spec['targets']['StreamCore']['sources']=[File.join(root,'StreamCore')]
spec['schemes']={'StreamCore'=>{'build'=>{'targets'=>{'StreamCore'=>'all'}}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
  xcodegen generate --spec "${BUILD_DIR}/project.json" --project "${BUILD_DIR}"
  xcodebuild -project "${BUILD_DIR}/GuestReturnAudioValidation.xcodeproj" -scheme StreamCore \
    -destination 'platform=macOS' -derivedDataPath "${BUILD_DIR}/core-derived" CODE_SIGNING_ALLOWED=NO build
  FRAMEWORKS="${BUILD_DIR}/core-derived/Build/Products/Debug"
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "${FRAMEWORKS}" -framework StreamCore \
  "${APPLE_DIR}/StreamMac/GuestMediaReceipts.swift" \
  "${APPLE_DIR}/StreamMac/IsolatedRecordingTypes.swift" "${APPLE_DIR}/StreamMac/IsolatedVideoTypes.swift" \
  "${APPLE_DIR}/StreamMac/RecordingChatTypes.swift" "${APPLE_DIR}/StreamMac/RecordingChatArchive.swift" \
  "${APPLE_DIR}/StreamMac/RecordingChatReader.swift" "${APPLE_DIR}/StreamMac/RecordingPreferences.swift" \
  "${APPLE_DIR}/StreamMac/ProgramRecordingSession.swift" "${APPLE_DIR}/StreamMac/AudioMixEngine.swift" \
  "${APPLE_DIR}/StreamMac/NativeGuestReturnAudioEncoder.swift" \
  "${SCRIPT_DIR}/guest_return_audio_harness.swift" -o "${BUILD_DIR}/GuestReturnAudioHarness"
env DYLD_FRAMEWORK_PATH="${FRAMEWORKS}" "${BUILD_DIR}/GuestReturnAudioHarness"
