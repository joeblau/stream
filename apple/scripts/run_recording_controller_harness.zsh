#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly RECORDING_CONTROLLER_BUILD_DIR="build/recording-controller-validation"
mkdir -p "$RECORDING_CONTROLLER_BUILD_DIR"
ruby -ryaml -rjson - "$RECORDING_CONTROLLER_BUILD_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='RecordingControllerValidation'
spec['packages']={}
spec['targets'].select!{|name,_| name == 'StreamCore'}
spec['targets']['StreamCore']['sources']=[File.join(root,'StreamCore')]
spec['schemes']={'StreamCore'=>{'build'=>{'targets'=>{'StreamCore'=>'all'}}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$RECORDING_CONTROLLER_BUILD_DIR/project.json" --project "$RECORDING_CONTROLLER_BUILD_DIR"
xcodebuild -project "$RECORDING_CONTROLLER_BUILD_DIR/RecordingControllerValidation.xcodeproj" \
  -scheme StreamCore -destination 'platform=macOS' \
  -derivedDataPath "$RECORDING_CONTROLLER_BUILD_DIR/derived" CODE_SIGNING_ALLOWED=NO build
readonly RECORDING_FRAMEWORKS="$RECORDING_CONTROLLER_BUILD_DIR/derived/Build/Products/Debug"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" -F "$RECORDING_FRAMEWORKS" -framework StreamCore \
  StreamMac/IsolatedRecordingTypes.swift StreamMac/IsolatedVideoTypes.swift StreamMac/IsolatedAudioRecorder.swift StreamMac/IsolatedVideoRecorder.swift StreamMac/RecordingChatTypes.swift StreamMac/RecordingChatArchive.swift StreamMac/RecordingChatReader.swift StreamMac/RecordingPreferences.swift StreamMac/ProgramRecordingSession.swift \
  StreamMac/SessionState.swift StreamMac/StudioEncoderReservations.swift StreamMac/RecordingController.swift \
  scripts/program_recording_fixtures.swift scripts/recording_controller_harness.swift \
  -o "$RECORDING_CONTROLLER_BUILD_DIR/RecordingControllerHarness"
readonly RECORDING_RUN_FOLDER="$RECORDING_CONTROLLER_BUILD_DIR/media-$(uuidgen)"
env DYLD_FRAMEWORK_PATH="$PWD/$RECORDING_FRAMEWORKS" \
  "$RECORDING_CONTROLLER_BUILD_DIR/RecordingControllerHarness" "$RECORDING_RUN_FOLDER"
