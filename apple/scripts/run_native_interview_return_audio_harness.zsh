#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly INTERVIEW_RETURN_DIR="${STREAM_INTERVIEW_RETURN_DIR:-build/native-interview-return-audio-validation}"
readonly INTERVIEW_RETURN_BUILD_PATH="${STREAM_INTERVIEW_RETURN_BUILD_PATH:-${INTERVIEW_RETURN_DIR}/derived}"
: ${STREAM_GUEST_RTC_INCLUDE:?Set the pinned public libdatachannel0.24 include path}
: ${STREAM_INTERVIEW_TURN_SERVER:?Set the owned pinned Coturn executable}
mkdir -p "$INTERVIEW_RETURN_DIR"
ruby -ryaml -rjson - "$INTERVIEW_RETURN_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='NativeInterviewReturnAudioValidation'
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
# Refuse the sole automatic local mic entry; source demand consists only of
# owned PCM and actual admitted guest media. Routing remains shipping code.
controller=File.read(File.join(root,'StreamMac/StreamController.swift')).gsub('UserDefaults.standard','GuestFixtureDefaults.value')
pattern=/    private func startAudioInput\(\) \{.*?\n    \}/m
abort 'Local microphone fixture boundary changed' unless controller.scan(pattern).length==1
controller.sub!(pattern,"    private func startAudioInput() {\n        InterviewCaptureBoundary.refusedMicrophoneStarts += 1\n    }")
controller_path=File.join(folder,'fixtures/InterviewProgramController.swift')
File.write(controller_path,controller)
target['sources'].reject!{|entry| entry.is_a?(String) && File.basename(entry)=='StreamController.swift'}
target['sources'][0]['excludes'] << 'StreamController.swift'
target['sources'] << controller_path
# Same-file read-only metadata; default factory, readiness and full-lease
# admission are untouched. Never expose addresses, credentials or SDP.
manager=File.read(File.join(root,'StreamMac/NativeInterviewManager.swift'))
manager += <<'SWIFT'

extension NativeInterviewManager {
    var fixtureSelectedICEPair: NativeGuestReceiver.ICEPair? {
        guard let current = currentReadyLease, current == registered,
              session?.readyPeerLease(for: current.receive.peerID) == current,
              let factory = binding?.factory as? NativeInterviewReceiverFactory else { return nil }
        return factory.selectedICEPair
    }

}
SWIFT
manager_path=File.join(folder,'fixtures/InterviewProgramManager.swift')
File.write(manager_path,manager)
target['sources'][0]['excludes'] << 'NativeInterviewManager.swift'
target['sources'] << manager_path
target['sources'] += ['native_interview_return_audio_cli.swift'].map{|file| File.join(root,'scripts',file)}
spec['targets']['NativeInterviewReturnAudioCLI']=target
spec['schemes']['NativeInterviewReturnAudioCLI']={'build'=>{'targets'=>{'NativeInterviewReturnAudioCLI'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$INTERVIEW_RETURN_DIR/project.json" --project "$INTERVIEW_RETURN_DIR"
xcodebuild -resolvePackageDependencies -project "$INTERVIEW_RETURN_DIR/NativeInterviewReturnAudioValidation.xcodeproj" \
  -scheme NativeInterviewReturnAudioCLI -derivedDataPath "$INTERVIEW_RETURN_BUILD_PATH"
# Optional read-only reuse of a qualified own derived artifact tree. The
# repair helper still verifies exact compiled policy/slice SHA and provenance.
if [[ -n "${STREAM_INTERVIEW_REFERENCE_ARTIFACTS:-}" ]]; then
  cp -R "$STREAM_INTERVIEW_REFERENCE_ARTIFACTS/." "$INTERVIEW_RETURN_BUILD_PATH/SourcePackages/artifacts/haishinkit.swift/"
fi
python3 scripts/repair_desktop_transport_archives.py "$INTERVIEW_RETURN_BUILD_PATH" --require-relay-policy
xcodebuild -project "$INTERVIEW_RETURN_DIR/NativeInterviewReturnAudioValidation.xcodeproj" -scheme NativeInterviewReturnAudioCLI \
  -destination 'platform=macOS' -derivedDataPath "$INTERVIEW_RETURN_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly INTERVIEW_RETURN_NODE="${STREAM_INTERVIEW_NODE:-node}"
"$INTERVIEW_RETURN_NODE" -e 'const [major,minor]=process.versions.node.split(".").map(Number); if(major!==24||minor<15) throw Error("Node >=24.15 <25 required")'
readonly INTERVIEW_RETURN_PRODUCTS="${INTERVIEW_RETURN_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$INTERVIEW_RETURN_PRODUCTS" \
  NATIVE_INTERVIEW_RETURN_AUDIO_CLI="$INTERVIEW_RETURN_PRODUCTS/NativeInterviewReturnAudioCLI" \
  "$INTERVIEW_RETURN_NODE" ../workers/interviews/test/browser/native-interview-return-audio-browser.mjs
