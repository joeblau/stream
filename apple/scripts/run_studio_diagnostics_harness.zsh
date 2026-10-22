#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly DIAGNOSTIC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stream-diagnostics.XXXXXX")"
trap 'rm -rf "$DIAGNOSTIC_DIR"' EXIT
# Compile the production data/export boundary without instantiating capture,
# publishers, AppKit windows or the main-window controller. No app build needed.
python3 - "$DIAGNOSTIC_DIR" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('StreamMac/StudioDiagnostics.swift').read_text()
source = source.split('/// The runtime owns timers, events, and delta baselines.')[0].replace('import StreamCore\n', '')
destination = Path('StreamMac/DestinationOutputController.swift').read_text()
destination = destination.split('struct DestinationDiagnosticSnapshot:')[1].split('private final class DestinationMailboxCounters:')[0]
protocols = Path('StreamCore/StreamSettings.swift').read_text().split('// MARK: - StreamSettings (the ONLY shared persisted model)')[0]
folder.joinpath('DiagnosticBoundary.swift').write_text(protocols + source + '\nstruct DestinationDiagnosticSnapshot:' + destination)
PY
# Compile the actual capability/protocol sources too; cached frameworks may
# have been built by another Xcode version and are deliberately not reused.
swiftc -parse-as-library StreamCore/OutputProfile.swift StreamCore/StreamCapability.swift StreamCore/AVClockTelemetry.swift \
    "$DIAGNOSTIC_DIR/DiagnosticBoundary.swift" scripts/studio_diagnostics_harness.swift \
    -o "$DIAGNOSTIC_DIR/diagnostics"
"$DIAGNOSTIC_DIR/diagnostics"
