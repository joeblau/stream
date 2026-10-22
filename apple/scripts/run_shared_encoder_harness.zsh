#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SHARED_ENCODER_DIR="build/shared-encoder-validation"
readonly SHARED_ENCODER_BUILD_PATH="${SHARED_ENCODER_BUILD_PATH:-$SHARED_ENCODER_DIR/derived}"
mkdir -p "$SHARED_ENCODER_DIR"
ruby -ryaml -rjson - "$SHARED_ENCODER_DIR" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
spec=YAML.load_file('project.yml')
spec['name']='SharedEncoderValidation'
spec['packages'].each_value{|p| p['path']=File.join(root,p['path']) if p['path']}
if ENV['STREAM_VENDOR_ROOT']
  spec['packages'].each_value{|p| p['path']=File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(p['path'])) if p['path']}
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
# Tool fixtures exercise host code; they neither embed nor activate extensions.
spec['targets'].each_value{|t| t['dependencies']&.reject!{|d| d['target'] && !spec['targets'].key?(d['target'])}}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['sources'].map!{|s| s.is_a?(String) ? File.join(root,s) : s.merge('path'=>File.join(root,s['path']))}
  target.delete('entitlements')
end
target=spec['targets'].delete('StreamMac')
target['type']='tool'
target['settings'] ||= {}
target['settings']['base'] ||= {}
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
target['sources'] << File.join(root,'scripts/shared_encoder_harness.swift')
target['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
spec['targets']['SharedEncoderHarness']=target
spec['schemes']['SharedEncoderHarness']={'build'=>{'targets'=>{'SharedEncoderHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(target, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$SHARED_ENCODER_DIR/project.json" --project "$SHARED_ENCODER_DIR"
xcodebuild -resolvePackageDependencies -project "$SHARED_ENCODER_DIR/SharedEncoderValidation.xcodeproj" \
  -scheme SharedEncoderHarness -derivedDataPath "$SHARED_ENCODER_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$SHARED_ENCODER_BUILD_PATH"
xcodebuild -project "$SHARED_ENCODER_DIR/SharedEncoderValidation.xcodeproj" \
  -scheme SharedEncoderHarness -destination 'platform=macOS' \
  -derivedDataPath "$SHARED_ENCODER_BUILD_PATH" -jobs "${STREAM_XCODE_JOBS:-2}" CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2' build
readonly SHARED_ENCODER_PRODUCTS="${SHARED_ENCODER_BUILD_PATH:A}/Build/Products/Debug"
run_shared_encoder_fixture() {
  env DYLD_FRAMEWORK_PATH="$SHARED_ENCODER_PRODUCTS" python3 - "$SHARED_ENCODER_PRODUCTS/SharedEncoderHarness" "$@" <<'PYTHON'
import os,signal,subprocess,sys
process=subprocess.Popen(sys.argv[1:],start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=90))
except subprocess.TimeoutExpired:
    # Only this generated fixture and its owned FFmpeg receivers share the group.
    os.killpg(process.pid,signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        process.wait()
    print('FAIL: shared encoder fixture exceeded90s; printed artifact directory retained',flush=True)
    raise SystemExit(1)
PYTHON
}
if (( $# > 0 )); then
  run_shared_encoder_fixture "$@"
  exit
fi
run_shared_encoder_fixture
run_shared_encoder_fixture --software
