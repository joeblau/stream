#!/bin/zsh

set -euo pipefail

# G07 (issue #114) browser-overlay measurement harness runner.
#
# Compiles the REAL app-target prototype (StreamMac/BrowserOverlayPrototype.swift)
# together with scripts/g07_browser_overlay_harness.swift as ONE module via
# swiftc — same pattern as the S06/S12 harnesses — and runs the measurement:
# cadence / snapshot latency / alpha correctness / CPU / interaction latency /
# widget-audio routing probes against the bundled BrowserFixtures. Build
# products land in the gitignored build/.
#
# The harness briefly shows a measurement window and plays a quiet synthesized
# audio sting (the audio-widget fixture). Screen Recording must be granted to
# the invoking terminal for the ScreenCaptureKit probe to resolve.

cd "${0:A:h:h}"

readonly HARNESS_DIR="build/g07-harness"
rm -rf "${HARNESS_DIR}"
mkdir -p "${HARNESS_DIR}"

# The prototype file has no StreamCore dependency, so it compiles as-is.
cp StreamMac/BrowserOverlayPrototype.swift "${HARNESS_DIR}/"
cp scripts/g07_browser_overlay_harness.swift "${HARNESS_DIR}/main.swift"

swiftc -swift-version 6 -O -o "${HARNESS_DIR}/g07-harness" "${HARNESS_DIR}"/*.swift
"${HARNESS_DIR}/g07-harness" "${PWD}/StreamMac/BrowserFixtures" "${HARNESS_DIR}/results.json"
