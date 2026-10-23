#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly WORKSPACE_DIR="${PERFORMANCE_DIR:-build/studio-performance-validation}"
readonly PERFORMANCE_BUILD_PATH="${PERFORMANCE_BUILD_PATH:-$WORKSPACE_DIR/derived}"
mkdir -p "$WORKSPACE_DIR"
readonly CYCLE_TRACE_MODE="${STUDIO_PERFORMANCE_CYCLE_TRACE:-0}"
if [[ "$CYCLE_TRACE_MODE" != 0 && "$CYCLE_TRACE_MODE" != 1 ]]; then
    print -u2 'STUDIO_PERFORMANCE_CYCLE_TRACE must be 0 or 1'
    exit 2
fi
cycle_trace_inputs=''
if [[ "$CYCLE_TRACE_MODE" == 1 ]]; then
    cycle_trace_inputs="${WORKSPACE_DIR:A}/cycle-trace-inputs/$(python3 -c 'import uuid; print(uuid.uuid4())')"
    python3 scripts/prepare_composition_cycle_trace.py --output "$cycle_trace_inputs"
fi
ruby -ryaml -rjson - "$WORKSPACE_DIR" "$cycle_trace_inputs" <<'RUBY'
root=Dir.pwd
folder=ARGV[0]
cycle_trace=ARGV[1]
spec=YAML.load_file('project.yml')
spec['name']='StudioPerformanceValidation'
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
h=spec['targets'].delete('StreamMac')
h['type']='tool'
h['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift']}
if cycle_trace.empty?
  h['sources'] << File.join(root,'scripts/studio_performance_harness.swift')
else
  h['sources'][0]['excludes'] << 'CompositionEngine.swift'
  h['sources'] << File.join(cycle_trace,'CompositionEngine.swift')
  h['sources'] << File.join(cycle_trace,'CompositionCycleTrace.swift')
  h['sources'] << File.join(cycle_trace,'studio_performance_harness.swift')
end
h['sources'] << File.join(root,'scripts/program_recording_fixtures.swift')
h['sources'] << File.join(root,'scripts/performance_owned_replay.swift')
h['sources'] << File.join(root,'scripts/performance_workload_evidence.swift')
spec['targets']['StudioPerformanceHarness']=h
spec['schemes']['StudioPerformanceHarness']={'build'=>{'targets'=>{'StudioPerformanceHarness'=>'all'}}}
require File.join(root, 'scripts/desktop_transport_fixture')
StreamDesktopTransportFixture.apply(h, root)
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$WORKSPACE_DIR/project.json" --project "$WORKSPACE_DIR"
xcodebuild -jobs 2 -resolvePackageDependencies -project "$WORKSPACE_DIR/StudioPerformanceValidation.xcodeproj" \
    -scheme StudioPerformanceHarness -derivedDataPath "$PERFORMANCE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$PERFORMANCE_BUILD_PATH"
xcodebuild -jobs 2 -project "$WORKSPACE_DIR/StudioPerformanceValidation.xcodeproj" \
    -scheme StudioPerformanceHarness -destination 'platform=macOS' \
    -derivedDataPath "$PERFORMANCE_BUILD_PATH" CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2' build
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
if [[ "$CYCLE_TRACE_MODE" == 1 ]]; then
    python3 scripts/retain_composition_cycle_trace_inputs.py --inputs "$cycle_trace_inputs" \
        --binary "${PERFORMANCE_BUILD_PATH:A}/Build/Products/Debug/StudioPerformanceHarness" \
        --frames "${WORKSPACE_DIR:A}/frames" --recipe "$WORKSPACE_DIR/project.json" \
        --xcode-project "$WORKSPACE_DIR/StudioPerformanceValidation.xcodeproj/project.pbxproj"
fi
sysctl -n hw.model machdep.cpu.brand_string
sw_vers
xcodebuild -version
env DYLD_FRAMEWORK_PATH="${PERFORMANCE_BUILD_PATH:A}/Build/Products/Debug" \
    python3 scripts/run_studio_performance_workloads.py \
    "${PERFORMANCE_BUILD_PATH:A}/Build/Products/Debug/StudioPerformanceHarness" "${WORKSPACE_DIR:A}/frames" "$@"
