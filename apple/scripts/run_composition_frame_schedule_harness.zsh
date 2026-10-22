#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly cadence_dir="${COMPOSITION_CADENCE_DIR:-build/composition-frame-schedule-validation}"
mkdir -p "$cadence_dir"
xcrun swiftc -swift-version 6 -j2 -parse-as-library \
  StreamMac/CompositionFrameSchedule.swift scripts/composition_frame_schedule_harness.swift \
  -o "$cadence_dir/CompositionFrameScheduleHarness"
"$cadence_dir/CompositionFrameScheduleHarness"
