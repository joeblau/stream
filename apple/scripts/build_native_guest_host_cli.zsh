#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
APPLE_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${STREAM_GUEST_BUILD_DIR:-${APPLE_DIR}/build/native-guest-receive}
: ${STREAM_GUEST_RTC_INCLUDE:?Set public pinned libdatachannel0.24 include directory containing rtc/}
: ${STREAM_GUEST_RTC_LIBRARY:?Set repaired pinned libdatachannel0.24 static library path}
[[ -f ${STREAM_GUEST_RTC_INCLUDE}/rtc/version.h && -f ${STREAM_GUEST_RTC_LIBRARY} ]]
mkdir -p "${BUILD_DIR}"
xcrun clang++ -std=c++17 -mmacosx-version-min=14.0 -I "${STREAM_GUEST_RTC_INCLUDE}" \
  -c "${APPLE_DIR}/NativeGuestReceivePrototype/GuestReceive.cpp" -o "${BUILD_DIR}/GuestReceive-host.o"
xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  -import-objc-header "${APPLE_DIR}/NativeGuestReceivePrototype/GuestReceive.h" \
  "${APPLE_DIR}/StreamMac/GuestMediaReceipts.swift" "${APPLE_DIR}/NativeGuestReceivePrototype/NativeGuestReceiver.swift" \
  "${SCRIPT_DIR}/native_guest_host_cli.swift" "${BUILD_DIR}/GuestReceive-host.o" \
  "${STREAM_GUEST_RTC_LIBRARY}" -Xlinker -lc++ -framework Security -framework CoreFoundation -lz -o "${BUILD_DIR}/guest-host-cli"
print "Native host fixture CLI: ${BUILD_DIR}/guest-host-cli"
