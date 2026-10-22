#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly STORAGE_NETWORK_DIR="${STORAGE_NETWORK_DIR:-build/recording-storage-network-validation}"
readonly STORAGE_NETWORK_BUILD_PATH="${STORAGE_NETWORK_BUILD_PATH:-$STORAGE_NETWORK_DIR/derived}"
mkdir -p "$STORAGE_NETWORK_DIR"
ruby -ryaml -rjson - "$STORAGE_NETWORK_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='RecordingStorageNetworkValidation'
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
target['sources'] += ['recording_storage_network_harness.swift','program_recording_fixtures.swift'].map{|name| File.join(root,'scripts',name)}
spec['targets']['RecordingStorageNetworkHarness']=target
spec['schemes']['RecordingStorageNetworkHarness']={'build'=>{'targets'=>{'RecordingStorageNetworkHarness'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$STORAGE_NETWORK_DIR/project.json" --project "$STORAGE_NETWORK_DIR"
xcodebuild -resolvePackageDependencies -project "$STORAGE_NETWORK_DIR/RecordingStorageNetworkValidation.xcodeproj" \
  -scheme RecordingStorageNetworkHarness -derivedDataPath "$STORAGE_NETWORK_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$STORAGE_NETWORK_BUILD_PATH"
xcodebuild -project "$STORAGE_NETWORK_DIR/RecordingStorageNetworkValidation.xcodeproj" -scheme RecordingStorageNetworkHarness \
  -destination 'platform=macOS' -derivedDataPath "$STORAGE_NETWORK_BUILD_PATH" CODE_SIGNING_ALLOWED=NO -jobs 2 build
readonly STORAGE_NETWORK_PRODUCTS="${STORAGE_NETWORK_BUILD_PATH:A}/Build/Products/Debug"
sysctl -n hw.model machdep.cpu.brand_string
sw_vers
xcodebuild -version
env DYLD_FRAMEWORK_PATH="$STORAGE_NETWORK_PRODUCTS" python3 - "$STORAGE_NETWORK_PRODUCTS/RecordingStorageNetworkHarness" "${STORAGE_NETWORK_DIR:A}" <<'PY'
import os,pathlib,signal,subprocess,sys,uuid
root=pathlib.Path(sys.argv[2])/('media-'+str(uuid.uuid4()))
root.mkdir()
process=subprocess.Popen([sys.argv[1],str(root)],env=os.environ.copy(),start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=90))
except subprocess.TimeoutExpired:
    # The generated tool and its owned FFmpeg receivers share this new group.
    # Terminate only that group if an encoder/framework call never returns.
    os.killpg(process.pid,signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        process.wait()
    print('FAIL: recording/network fixture exceeded 90 s; owned media retained at '+str(root),flush=True)
    raise SystemExit(1)
PY
