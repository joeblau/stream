#!/bin/zsh

set -euo pipefail

if [[ -z "${STREAM_DEVICE_ID:-}" ]]; then
    typeset -a available_iphones
    available_iphones=("${(@f)$(xcrun devicectl list devices \
        --filter "properties.hardware.reality = 'physical' AND properties.hardware.deviceType = 'iPhone' AND properties.connection.pairingState = 'paired' AND properties.state.bootState = 'booted'" \
        --columns 'properties.hardware.udid' \
        --hide-default-columns \
        --hide-headers)}")
    if (( ${#available_iphones} != 1 )); then
        print -u2 "Expected one paired, unlocked physical iPhone; found ${#available_iphones}."
        print -u2 "Connect one device or run STREAM_DEVICE_ID=<UDID> bun stream."
        exit 1
    fi
    STREAM_DEVICE_ID="${available_iphones[1]}"
fi
readonly STREAM_DEVICE_ID
readonly STREAM_DESTINATION="platform=iOS,id=${STREAM_DEVICE_ID}"
readonly STREAM_DERIVED_DATA_PATH="build/device"
readonly STREAM_APP_PATH="${STREAM_DERIVED_DATA_PATH}/Build/Products/Debug-iphoneos/Stream.app"
readonly STREAM_BUNDLE_ID="com.joeblau.Stream"

if ! xcrun devicectl list devices \
    --filter "properties.hardware.udid = '${STREAM_DEVICE_ID}' AND properties.hardware.reality = 'physical' AND properties.hardware.deviceType = 'iPhone' AND properties.connection.pairingState = 'paired' AND properties.state.bootState = 'booted'" \
    --columns 'properties.hardware.udid' \
    --hide-default-columns \
    --hide-headers | grep -Fqx "${STREAM_DEVICE_ID}"; then
    print -u2 "The selected iPhone is unavailable. Unlock it and connect it to this Mac, then try again."
    exit 1
fi

print "Building Stream for ${STREAM_DEVICE_ID}..."
xcodebuild \
    -project Stream.xcodeproj \
    -scheme Stream \
    -configuration Debug \
    -destination "${STREAM_DESTINATION}" \
    -derivedDataPath "${STREAM_DERIVED_DATA_PATH}" \
    -allowProvisioningUpdates \
    build

if [[ ! -d "${STREAM_APP_PATH}" ]]; then
    print -u2 "Build succeeded, but ${STREAM_APP_PATH} was not found."
    exit 1
fi

print "Installing Stream..."
xcrun devicectl device install app \
    --device "${STREAM_DEVICE_ID}" \
    "${STREAM_APP_PATH}"

print "Launching Stream..."
xcrun devicectl device process launch \
    --device "${STREAM_DEVICE_ID}" \
    --terminate-existing \
    "${STREAM_BUNDLE_ID}"
