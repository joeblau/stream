#!/bin/zsh

set -euo pipefail

# S12 (issue #75) standalone assertion harness runner.
#
# The scene model and migration types live in the StreamMac app target (no
# test bundle exists for it), so this compiles the real sources as ONE module
# with swiftc — stripping the `import StreamCore` lines and pulling in the two
# StreamCore files that define PIPCorner — then runs the assertions in
# scene_s12_harness.swift. Build products land in the gitignored build/.

cd "${0:A:h:h}"

readonly HARNESS_DIR="build/s12-harness"
rm -rf "${HARNESS_DIR}"
mkdir -p "${HARNESS_DIR}"

# Sources under test, compiled as one module (StreamCore import stripped).
typeset -a sources
sources=(
    StreamCore/StreamSettings.swift
    StreamCore/OutputProfile.swift
    StreamCore/StreamCapability.swift
    StreamMac/LayerGraph.swift
    StreamMac/SceneMigration.swift
    StreamMac/SceneDocumentMigration.swift
    StreamMac/SceneUndoStack.swift
)
for source in "${sources[@]}"; do
    sed 's/^import StreamCore$//' "${source}" > "${HARNESS_DIR}/${source:t}"
done
cp scripts/scene_s12_harness.swift "${HARNESS_DIR}/main.swift"

swiftc -swift-version 6 -o "${HARNESS_DIR}/s12-harness" "${HARNESS_DIR}"/*.swift
"${HARNESS_DIR}/s12-harness"
