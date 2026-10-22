#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${BROWSER_STOP_CORE_FRAMEWORK:?Set an immutable matching StreamCore.framework path}"
readonly STOP_DIR="${BROWSER_STOP_BUILD_DIR:-$PWD/build/browser-stop-confirmation}"
python3 scripts/browser_stop_confirmation_fixture.py "$PWD" "$STOP_DIR" "$BROWSER_STOP_CORE_FRAMEWORK"
