#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_RETURN_BUILD_DIR:-${APPLE_DIR}/build/guest-return-sender-diagnostics}
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
    -destination 'platform=macOS' -derivedDataPath "${BUILD_DIR}/core-derived" -jobs 2 CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2' build
  FRAMEWORKS="${BUILD_DIR}/core-derived/Build/Products/Debug"
fi
reference_arguments=()
if [[ -n "${STREAM_GUEST_RFC_OPUS_LIBRARY:-}" ]]; then
  [[ "$STREAM_GUEST_RFC_OPUS_LIBRARY" == /* && -f "$STREAM_GUEST_RFC_OPUS_LIBRARY" ]] || { print -u2 'Set an existing absolute libopus file; no dependency installation is performed.'; exit 1; }
  reference_arguments=(-D STREAM_GUEST_RFC_OPUS_VALIDATION "${SCRIPT_DIR}/guest_return_reference_opus.swift")
fi
xcrun swiftc -j2 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "${FRAMEWORKS}" -framework StreamCore \
  "${APPLE_DIR}/StreamMac/GuestMediaReceipts.swift" \
  "${APPLE_DIR}/StreamMac/IsolatedRecordingTypes.swift" "${APPLE_DIR}/StreamMac/IsolatedVideoTypes.swift" \
  "${APPLE_DIR}/StreamMac/RecordingChatTypes.swift" "${APPLE_DIR}/StreamMac/RecordingChatArchive.swift" \
  "${APPLE_DIR}/StreamMac/RecordingChatReader.swift" "${APPLE_DIR}/StreamMac/RecordingPreferences.swift" \
  "${APPLE_DIR}/StreamMac/ProgramRecordingSession.swift" "${APPLE_DIR}/StreamMac/AudioMixEngine.swift" \
  "${APPLE_DIR}/StreamMac/NativeGuestReturnAudioEncoder.swift" \
  "${SCRIPT_DIR}/guest_return_sender_diagnostics.swift" \
  "${SCRIPT_DIR}/guest_return_sender_local_harness.swift" "${reference_arguments[@]}" -o "${BUILD_DIR}/GuestReturnSenderDiagnostic"
env DYLD_FRAMEWORK_PATH="${FRAMEWORKS}" "${BUILD_DIR}/GuestReturnSenderDiagnostic"
