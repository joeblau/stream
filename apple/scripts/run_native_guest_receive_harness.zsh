#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_BUILD_DIR:-${APPLE_DIR}/build/native-guest-receive}
: ${STREAM_GUEST_RTC_INCLUDE:?Set public pinned libdatachannel0.24 include directory containing rtc/}
: ${STREAM_GUEST_RTC_LIBRARY:?Set repaired pinned libdatachannel0.24 static library path}
[[ -f ${STREAM_GUEST_RTC_INCLUDE}/rtc/version.h && -f ${STREAM_GUEST_RTC_LIBRARY} ]]
mkdir -p "${BUILD_DIR}"
python3 "${SCRIPT_DIR}/prepare_guest_receive_fixtures.py" "${BUILD_DIR}/fixtures"
xcrun clang++ -std=c++17 -DSTREAM_GUEST_VALIDATION -mmacosx-version-min=14.0 -I "${STREAM_GUEST_RTC_INCLUDE}" \
  -c "${APPLE_DIR}/NativeGuestReceivePrototype/GuestReceive.cpp" -o "${BUILD_DIR}/GuestReceive.o"
xcrun clang++ -std=c++17 -mmacosx-version-min=14.0 -I "${STREAM_GUEST_RTC_INCLUDE}" \
  -c "${SCRIPT_DIR}/guest_receive_peer_fixture.cpp" -o "${BUILD_DIR}/PeerFixture.o"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.0" -DSTREAM_GUEST_VALIDATION -Xcc -DSTREAM_GUEST_VALIDATION \
  -parse-as-library -import-objc-header "${SCRIPT_DIR}/guest_receive_peer_fixture.h" \
  "${APPLE_DIR}/StreamMac/GuestMediaReceipts.swift" "${APPLE_DIR}/NativeGuestReceivePrototype/NativeGuestReceiver.swift" \
  "${SCRIPT_DIR}/native_guest_receive_harness.swift" "${BUILD_DIR}/GuestReceive.o" "${BUILD_DIR}/PeerFixture.o" \
  "${STREAM_GUEST_RTC_LIBRARY}" -Xlinker -lc++ -framework Security -framework CoreFoundation -lz -o "${BUILD_DIR}/guest-harness"
"${BUILD_DIR}/guest-harness" "${BUILD_DIR}/fixtures" "$@"
