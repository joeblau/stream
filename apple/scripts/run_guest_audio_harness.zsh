#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_AUDIO_BUILD_DIR:-${APPLE_DIR}/build/guest-audio-validation}
FRAMEWORKS=${STREAM_GUEST_AUDIO_FRAMEWORKS:-${BUILD_DIR}/core-derived/Build/Products/Debug}
mkdir -p "${BUILD_DIR}"
if [[ ! -d "${FRAMEWORKS}/StreamCore.framework" ]]; then
  # Core-only generated project: no packages, credentials, permissions or devices.
  ruby -ryaml -rjson - "${APPLE_DIR}" "${BUILD_DIR}" <<'RUBY'
root,folder=ARGV
spec=YAML.load_file(File.join(root,'project.yml'))
spec['name']='GuestAudioValidation'
spec['packages']={}
spec['targets'].select!{|name,_| name=='StreamCore'}
spec['targets']['StreamCore']['sources']=[File.join(root,'StreamCore')]
spec['schemes']={'StreamCore'=>{'build'=>{'targets'=>{'StreamCore'=>'all'}}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
  xcodegen generate --spec "${BUILD_DIR}/project.json" --project "${BUILD_DIR}"
  xcodebuild -project "${BUILD_DIR}/GuestAudioValidation.xcodeproj" -scheme StreamCore \
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
  "${SCRIPT_DIR}/program_recording_fixtures.swift" "${SCRIPT_DIR}/guest_audio_harness.swift" \
  -o "${BUILD_DIR}/GuestAudioHarness"
env DYLD_FRAMEWORK_PATH="${FRAMEWORKS}" "${BUILD_DIR}/GuestAudioHarness" "${BUILD_DIR}/media-$(uuidgen)"
