#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly AUTOMATION_DIR="build/studio-automation-validation"
mkdir -p "$AUTOMATION_DIR"
# The production endpoint only imports StreamCore for graph types supplied by
# the minimal dispatcher below. An empty module keeps the test independent of
# publisher/vendor builds while compiling the actual endpoint and App Intents.
print '' > "$AUTOMATION_DIR/StreamCore.swift"
swiftc -swift-version 6 -emit-module -module-name StreamCore "$AUTOMATION_DIR/StreamCore.swift" -emit-module-path "$AUTOMATION_DIR/StreamCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$AUTOMATION_DIR" -framework AppKit -framework AppIntents \
  StreamMac/StudioAutomationModel.swift StreamMac/StudioAutomationEndpoint.swift StreamMac/StudioAppIntents.swift \
  scripts/studio_automation_harness.swift -o "$AUTOMATION_DIR/harness"
"$AUTOMATION_DIR/harness"
