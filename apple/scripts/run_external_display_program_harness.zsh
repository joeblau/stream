#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly EXTERNAL_PROGRAM_DIR="${EXTERNAL_PROGRAM_DIR:-build/external-display-program-validation}"
readonly EXTERNAL_PROGRAM_BUILD_PATH="${EXTERNAL_PROGRAM_BUILD_PATH:-$EXTERNAL_PROGRAM_DIR/derived}"
mkdir -p "$EXTERNAL_PROGRAM_DIR"
ruby -ryaml -rjson - "$EXTERNAL_PROGRAM_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='ExternalDisplayProgramValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path']=ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'],File.basename(package['path'])) : File.join(root,package['path'])
end
spec['targets'].select!{|name,_| ['StreamCore','StreamMac'].include?(name)}
spec['schemes']={}
spec['targets'].each_value do |target|
  target['dependencies']&.reject!{|dependency| dependency['target'] && !spec['targets'].key?(dependency['target'])}
  target['sources'].map!{|source| source.is_a?(String) ? File.join(root,source) : source.merge('path'=>File.join(root,source['path']))}
  target.delete('entitlements'); target.delete('info')
end
target=spec['targets'].delete('StreamMac'); target['type']='tool'
require File.join(root,'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'],target,root,folder)
# Deny the local microphone permission boundary without changing mixer,
# compositor, recorder, publisher, cleanup or source-clock implementation.
audio=File.read(File.join(root,'StreamMac/MacAudioInput.swift')).gsub('UserDefaults.standard','GuestFixtureDefaults.value')
boundary=/    private nonisolated static func requestMicrophoneAccess\(\) async -> Bool \{.*?\n    \}\n\n    private func configureAndStart/m
abort 'Microphone capture boundary changed' unless audio.match?(boundary)
audio.sub!(boundary,"    private nonisolated static func requestMicrophoneAccess() async -> Bool { false }\n\n    private func configureAndStart")
audio_path=File.join(folder,'fixtures/MacAudioInput.swift')
File.write(audio_path,audio)
target['sources'].reject!{|entry| entry.is_a?(String) && File.basename(entry)=='MacAudioInput.swift'}
target['sources'][0]['excludes'] << 'MacAudioInput.swift'
target['sources'] << audio_path
target['sources'] += ['external_display_program_harness.swift'].map{|name| File.join(root,'scripts',name)}
# All permission decisions belong to the fixture; no TCC requests or settings UI.
permissions=File.read(File.join(root,'StreamMac/PermissionsManager.swift'))
{ /    func refresh\(\) \{.*?\n    \}/m => '    func refresh() { statuses = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, .denied) }) }',
  /    func probeScreenAccess\(\) async \{.*?\n    \}/m => '    func probeScreenAccess() async { refresh() }',
  /    func request\(_ kind: Kind\) async -> Status \{.*?\n    \}/m => '    func request(_ kind: Kind) async -> Status { .denied }',
  /    func openSystemSettings\(for kind: Kind\) \{.*?\n    \}/m => '    func openSystemSettings(for kind: Kind) {}' }.each do |seam,replacement|
  abort 'Permission boundary changed' unless permissions.match?(seam)
  permissions.sub!(seam,replacement)
end
permissions_path=File.join(folder,'fixtures/PermissionsManager.swift'); File.write(permissions_path,permissions)
target['sources'].reject!{|entry| entry.is_a?(String) && File.basename(entry)=='PermissionsManager.swift'}
target['sources'][0]['excludes'] << 'PermissionsManager.swift' unless target['sources'][0]['excludes'].include?('PermissionsManager.swift')
target['sources'] << permissions_path
spec['targets']['ExternalDisplayProgramHarness']=target
spec['schemes']['ExternalDisplayProgramHarness']={'build'=>{'targets'=>{'ExternalDisplayProgramHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$EXTERNAL_PROGRAM_DIR/project.json" --project "$EXTERNAL_PROGRAM_DIR"
xcodebuild -resolvePackageDependencies -project "$EXTERNAL_PROGRAM_DIR/ExternalDisplayProgramValidation.xcodeproj" \
  -scheme ExternalDisplayProgramHarness -derivedDataPath "$EXTERNAL_PROGRAM_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$EXTERNAL_PROGRAM_BUILD_PATH"
xcodebuild -project "$EXTERNAL_PROGRAM_DIR/ExternalDisplayProgramValidation.xcodeproj" -scheme ExternalDisplayProgramHarness \
  -destination 'platform=macOS' -derivedDataPath "$EXTERNAL_PROGRAM_BUILD_PATH" CODE_SIGNING_ALLOWED=NO -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' build
readonly EXTERNAL_PROGRAM_PRODUCTS="${EXTERNAL_PROGRAM_BUILD_PATH:A}/Build/Products/Debug"
sysctl -n hw.model machdep.cpu.brand_string
sw_vers
xcodebuild -version
env DYLD_FRAMEWORK_PATH="$EXTERNAL_PROGRAM_PRODUCTS" python3 - "$EXTERNAL_PROGRAM_PRODUCTS/ExternalDisplayProgramHarness" "${EXTERNAL_PROGRAM_DIR:A}/artifacts-$(uuidgen)" <<'PY'
import os,pathlib,signal,subprocess,sys,uuid
root=pathlib.Path(sys.argv[2])
root.mkdir(parents=True)
process=subprocess.Popen([sys.argv[1],str(root)],env=os.environ.copy(),start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=90))
except subprocess.TimeoutExpired:
    # Bound the generated tool and its fixture-owned windows.
    # Terminate only that group if an encoder/framework call never returns.
    os.killpg(process.pid,signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        process.wait()
    print('FAIL: external display fixture exceeded 90 s; owned pixels retained at '+str(root),flush=True)
    raise SystemExit(1)
PY
