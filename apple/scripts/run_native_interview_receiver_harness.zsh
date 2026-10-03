#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_INTERVIEW_RECEIVER_BUILD_DIR:-${APPLE_DIR}/build/native-interview-receiver}
: ${STREAM_GUEST_RTC_INCLUDE:?Set qualified pinned public libdatachannel include path}
: ${STREAM_GUEST_RTC_LIBRARY:?Set qualified pinned public libdatachannel archive path}
: ${STREAM_INTERVIEW_RECEIVER_FRAMEWORKS:?Set isolated StreamCore framework directory}
mkdir -p "${BUILD_DIR}"
xcrun clang++ -std=c++17 -DSTREAM_GUEST_VALIDATION -mmacosx-version-min=14.0 -I "${STREAM_GUEST_RTC_INCLUDE}" \
  -c "${APPLE_DIR}/NativeGuestReceivePrototype/GuestReceive.cpp" -o "${BUILD_DIR}/GuestReceive.o"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -DSTREAM_GUEST_VALIDATION -Xcc -DSTREAM_GUEST_VALIDATION \
  -target "$(uname -m)-apple-macos14.0" -F "${STREAM_INTERVIEW_RECEIVER_FRAMEWORKS}" -framework StreamCore \
  -import-objc-header "${APPLE_DIR}/NativeGuestReceivePrototype/GuestReceive.h" \
  "${APPLE_DIR}/StreamMac/GuestMediaReceipts.swift" "${APPLE_DIR}/StreamMac/GuestVideoFrameStore.swift" \
  "${APPLE_DIR}/StreamMac/IsolatedRecordingTypes.swift" "${APPLE_DIR}/StreamMac/IsolatedVideoTypes.swift" \
  "${APPLE_DIR}/StreamMac/RecordingChatTypes.swift" "${APPLE_DIR}/StreamMac/RecordingChatArchive.swift" \
  "${APPLE_DIR}/StreamMac/RecordingChatReader.swift" "${APPLE_DIR}/StreamMac/RecordingPreferences.swift" \
  "${APPLE_DIR}/StreamMac/ProgramRecordingSession.swift" "${APPLE_DIR}/StreamMac/AudioMixEngine.swift" \
  "${APPLE_DIR}/StreamMac/NativeGuestReturnAudioEncoder.swift" \
  "${APPLE_DIR}/NativeGuestReceivePrototype/NativeGuestReceiver.swift" \
  "${APPLE_DIR}/StreamMac/NativeInterviewTypes.swift" "${APPLE_DIR}/StreamMac/NativeGuestMediaSink.swift" \
  "${APPLE_DIR}/StreamMac/NativeInterviewReceiverAdapter.swift" \
  "${SCRIPT_DIR}/program_recording_fixtures.swift" "${SCRIPT_DIR}/native_interview_receiver_harness.swift" \
  "${BUILD_DIR}/GuestReceive.o" "${STREAM_GUEST_RTC_LIBRARY}" -Xlinker -lc++ -lz \
  -framework Security -framework CoreFoundation -o "${BUILD_DIR}/NativeInterviewReceiverHarness"
env DYLD_FRAMEWORK_PATH="${STREAM_INTERVIEW_RECEIVER_FRAMEWORKS}" "${BUILD_DIR}/NativeInterviewReceiverHarness"
