#!/bin/zsh

set -euo pipefail

# S06 (issue #96) standalone assertion harness runner.
#
# The scene model types live in the StreamMac app target (no test bundle
# exists for it), so — same pattern as the S12 harness — this compiles the
# real sources as ONE module with swiftc (stripping the `import StreamCore`
# lines and pulling in the StreamCore files that define PIPCorner), then runs
# the assertions in scene_s06_harness.swift. Build products land in the
# gitignored build/.

cd "${0:A:h:h}"

readonly HARNESS_DIR="build/s06-harness"
rm -rf "${HARNESS_DIR}"
mkdir -p "${HARNESS_DIR}"

# Sources under test, compiled as one module (StreamCore import stripped).
typeset -a sources
sources=(
    StreamCore/StreamSettings.swift
    StreamCore/OutputProfile.swift
    StreamCore/StreamCapability.swift
    StreamMac/LayerGraph.swift
)
for source in "${sources[@]}"; do
    sed 's/^import StreamCore$//' "${source}" > "${HARNESS_DIR}/${source:t}"
done
cp scripts/scene_s06_harness.swift "${HARNESS_DIR}/main.swift"

swiftc -swift-version 6 -o "${HARNESS_DIR}/s06-harness" "${HARNESS_DIR}"/*.swift
"${HARNESS_DIR}/s06-harness"
