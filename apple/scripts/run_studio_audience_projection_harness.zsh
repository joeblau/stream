#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly AUDIENCE_PROJECTION_DIR="build/studio-audience-projection-validation"
mkdir -p "$AUDIENCE_PROJECTION_DIR"
python3 - "$AUDIENCE_PROJECTION_DIR" <<'PY'
import pathlib,sys
folder=pathlib.Path(sys.argv[1])
controller=pathlib.Path('StreamMac/StudioInteractionController.swift').read_text()
start=controller.index('    func audienceSnapshot(now: Date = Date()) -> StudioControlAudienceState {')
end=controller.index('\n    }\n',start)+len('\n    }\n')
method=controller[start:end]
wire=pathlib.Path('StreamMac/StudioControlProtocol.swift').read_text()
start=wire.index('struct StudioControlAudienceState:')
end=wire.index('\n}\n',start)+len('\n}\n')
record=wire[start:end]
fixture=pathlib.Path('scripts/studio_audience_projection_harness.swift').read_text()
assert fixture.count('// PRODUCTION_AUDIENCE_RECORD')==1 and fixture.count('// PRODUCTION_AUDIENCE_MAPPER')==1
fixture=fixture.replace('// PRODUCTION_AUDIENCE_RECORD',record).replace('// PRODUCTION_AUDIENCE_MAPPER',method)
(folder/'harness.swift').write_text(fixture)
PY
swiftc -swift-version 6 -j 2 -parse-as-library "$AUDIENCE_PROJECTION_DIR/harness.swift" -o "$AUDIENCE_PROJECTION_DIR/harness"
"$AUDIENCE_PROJECTION_DIR/harness"
