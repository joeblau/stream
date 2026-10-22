#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly PROFILE_DIR="${COMPOSITION_PROFILE_DIR:-build/composition-hotpath-profile}"
readonly PROFILE_BUILD_PATH="${COMPOSITION_PROFILE_BUILD_PATH:-$PROFILE_DIR/derived}"
python3 scripts/prepare_composition_hotpath_profile.py --output "$PROFILE_DIR"
xcodegen generate --spec "$PROFILE_DIR/project.json" --project "$PROFILE_DIR"
xcodebuild -jobs 2 -resolvePackageDependencies -project "$PROFILE_DIR/CompositionHotPathProfile.xcodeproj" \
    -scheme StudioPerformanceHarness -derivedDataPath "$PROFILE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$PROFILE_BUILD_PATH"
xcodebuild -jobs 2 -project "$PROFILE_DIR/CompositionHotPathProfile.xcodeproj" -scheme StudioPerformanceHarness \
    -destination 'platform=macOS' -derivedDataPath "$PROFILE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='$(inherited) -j2' build
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
env DYLD_FRAMEWORK_PATH="${PROFILE_BUILD_PATH:A}/Build/Products/Debug" \
    STREAM_FIXTURE_AUDIO_DECODER=av-audio-file \
    python3 - "${PROFILE_BUILD_PATH:A}/Build/Products/Debug/StudioPerformanceHarness" "${PROFILE_DIR:A}/frames" <<'PY'
import os,signal,subprocess,sys
process=subprocess.Popen([sys.argv[1],sys.argv[2],'--sustained'],start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=180))
finally:
    if process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);process.wait()
PY
