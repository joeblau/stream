#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly EPOCH_FIXTURE_DIR="${COMPOSITION_SLEEP_EPOCH_DIR:-build/composition-sleep-epoch-validation}"
mkdir -p "$EPOCH_FIXTURE_DIR"
swiftc -swift-version 6 -j2 scripts/composition_hotpath_profile.swift \
    scripts/composition_sleep_epoch_harness.swift -o "$EPOCH_FIXTURE_DIR/CompositionSleepEpochHarness"
"$EPOCH_FIXTURE_DIR/CompositionSleepEpochHarness" "${EPOCH_FIXTURE_DIR:A}"
