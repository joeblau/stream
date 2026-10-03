#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly INTERVIEW_PROGRAM_DIR="${STREAM_INTERVIEW_PROGRAM_DIR:-build/native-interview-program-iso-validation}"
readonly INTERVIEW_PROGRAM_BUILD_PATH="${STREAM_INTERVIEW_PROGRAM_BUILD_PATH:-${INTERVIEW_PROGRAM_DIR}/derived}"
: ${STREAM_GUEST_RTC_INCLUDE:?Set the pinned public libdatachannel0.24 include path}
: ${STREAM_INTERVIEW_TURN_SERVER:?Set the owned pinned Coturn executable}
mkdir -p "$INTERVIEW_PROGRAM_DIR"
ruby -ryaml -rjson - "$INTERVIEW_PROGRAM_DIR" <<'RUBY'
root=Dir.pwd
folder=File.expand_path(ARGV[0])
spec=YAML.load_file('project.yml')
spec['name']='NativeInterviewProgramISOValidation'
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
# actual registered guest layers. Composer/mixer/controller routing stays real.
controller=File.read(File.join(root,'StreamMac/StreamController.swift')).gsub('UserDefaults.standard','GuestFixtureDefaults.value')
pattern=/    private func startAudioInput\(\) \{.*?\n    \}/m
abort 'Local microphone fixture boundary changed' unless controller.scan(pattern).length==1
controller.sub!(pattern,"    private func startAudioInput() {\n        InterviewCaptureBoundary.refusedMicrophoneStarts += 1\n    }")
inlet='NativeGuestMediaSink(registered: lease, video: guestVideoFrames, audio: audioEngine)'
abort 'Registered sink observer fixture boundary changed' unless controller.scan(inlet).length==1
controller.sub!(inlet,'NativeGuestMediaSink(registered: lease, video: guestVideoFrames, audio: audioEngine, acceptedVideo: { InterviewDecodedProbe.value.picture($0) }, acceptedAudio: { InterviewDecodedProbe.value.sound($0) })')
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
    var fixtureReceiverDiagnostics: [String: Any]? {
        guard let current = currentReadyLease, current == registered,
              session?.readyPeerLease(for: current.receive.peerID) == current,
              let factory = binding?.factory as? NativeInterviewReceiverFactory else { return nil }
        return factory.fixtureReceiverDiagnostics
    }
}
SWIFT
manager_path=File.join(folder,'fixtures/InterviewProgramManager.swift')
File.write(manager_path,manager)
target['sources'][0]['excludes'] << 'NativeInterviewManager.swift'
target['sources'] << manager_path
adapter=File.read(File.join(root,'StreamMac/NativeInterviewReceiverAdapter.swift'))
adapter += <<'SWIFT'

extension NativeInterviewReceiverAdapter {
    var fixtureReceiverDiagnostics: [String: Any]? {
        guard !isRetired else { return nil }
        let counts = receiver.counters
        let roles = receiver.diagnosticSnapshot().map { value -> [String: Any] in
            let transport = receiver.transportStats(value.role)
            return ["role": value.role.rawValue, "received": value.received, "decoded": value.decoded,
                    "expired": value.expired, "queued": value.queued, "srAge": value.senderReportAge ?? -1,
                    "rtpFrames": transport.frames, "rtpRejected": transport.rejected,
                    "codec": value.statuses.map { ["stage": $0.stage, "status": $0.status, "detail": $0.detail] as [String: Any] }]
        }
        return ["errors": counts.errors, "drops": counts.dropped, "unsynchronized": counts.unsynchronized, "roles": roles]
    }
}
extension NativeInterviewReceiverFactory {
    var fixtureReceiverDiagnostics: [String: Any]? { closed ? nil : current?.fixtureReceiverDiagnostics }
}
SWIFT
adapter_path=File.join(folder,'fixtures/InterviewProgramReceiverAdapter.swift')
File.write(adapter_path,adapter)
target['sources'][0]['excludes'] << 'NativeInterviewReceiverAdapter.swift'
target['sources'] << adapter_path
store=File.read(File.join(root,'StreamMac/GuestVideoFrameStore.swift'))
store += <<'SWIFT'

extension GuestVideoFrameStore {
    func fixtureHistory(lease current: GuestReceiveLease, role: GuestReceiveRole) -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }
        guard lease == current, let frames = roles[role]?.frames, let first = frames.first, let last = frames.last else { return nil }
        return (first.pts.seconds, last.pts.seconds)
    }
}
SWIFT
store_path=File.join(folder,'fixtures/InterviewProgramFrameStore.swift')
File.write(store_path,store)
target['sources'][0]['excludes'] << 'GuestVideoFrameStore.swift'
target['sources'] << store_path
factory=File.read(File.join(root,'StreamMac/RecordingVideoSourceFactory.swift'))
needle='            let snapshot = Snapshot(camera: nil, pixels: pixels)'
abort 'Guest ISO query observer boundary changed' unless factory.scan(needle).length==1
factory.sub!(needle,<<'SWIFT')
            if pixels == nil {
                InterviewDecodedProbe.value.missing(lease: lease, at: pts,
                    history: frames.fixtureHistory(lease: lease, role: payload.role == .camera ? .camera : .screen))
            }
            let snapshot = Snapshot(camera: nil, pixels: pixels)
SWIFT
factory_path=File.join(folder,'fixtures/InterviewProgramSourceFactory.swift')
File.write(factory_path,factory)
target['sources'][0]['excludes'] << 'RecordingVideoSourceFactory.swift'
target['sources'] << factory_path
target['sources'] += ['native_interview_program_iso_cli.swift','native_interview_program_iso_analysis.swift'].map{|file| File.join(root,'scripts',file)}
spec['targets']['NativeInterviewProgramISOCLI']=target
spec['schemes']['NativeInterviewProgramISOCLI']={'build'=>{'targets'=>{'NativeInterviewProgramISOCLI'=>'all'}}}
File.write(File.join(folder,'project.json'),JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$INTERVIEW_PROGRAM_DIR/project.json" --project "$INTERVIEW_PROGRAM_DIR"
xcodebuild -resolvePackageDependencies -project "$INTERVIEW_PROGRAM_DIR/NativeInterviewProgramISOValidation.xcodeproj" \
  -scheme NativeInterviewProgramISOCLI -derivedDataPath "$INTERVIEW_PROGRAM_BUILD_PATH"
# Optional read-only reuse of a qualified own derived artifact tree. The
# repair helper still verifies exact compiled policy/slice SHA and provenance.
if [[ -n "${STREAM_INTERVIEW_REFERENCE_ARTIFACTS:-}" ]]; then
  cp -R "$STREAM_INTERVIEW_REFERENCE_ARTIFACTS/." "$INTERVIEW_PROGRAM_BUILD_PATH/SourcePackages/artifacts/haishinkit.swift/"
fi
python3 scripts/repair_desktop_transport_archives.py "$INTERVIEW_PROGRAM_BUILD_PATH" --require-relay-policy
xcodebuild -project "$INTERVIEW_PROGRAM_DIR/NativeInterviewProgramISOValidation.xcodeproj" -scheme NativeInterviewProgramISOCLI \
  -destination 'platform=macOS' -derivedDataPath "$INTERVIEW_PROGRAM_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly INTERVIEW_PROGRAM_NODE="${STREAM_INTERVIEW_NODE:-node}"
"$INTERVIEW_PROGRAM_NODE" -e 'const [major,minor]=process.versions.node.split(".").map(Number); if(major!==24||minor<15) throw Error("Node >=24.15 <25 required")'
readonly INTERVIEW_PROGRAM_PRODUCTS="${INTERVIEW_PROGRAM_BUILD_PATH:A}/Build/Products/Debug"
env DYLD_FRAMEWORK_PATH="$INTERVIEW_PROGRAM_PRODUCTS" \
  NATIVE_INTERVIEW_PROGRAM_ISO_CLI="$INTERVIEW_PROGRAM_PRODUCTS/NativeInterviewProgramISOCLI" \
  STREAM_INTERVIEW_PROGRAM_ARTIFACTS="${INTERVIEW_PROGRAM_DIR:A}/media-$(uuidgen)" \
  "$INTERVIEW_PROGRAM_NODE" ../workers/interviews/test/browser/native-interview-program-iso-browser.mjs
