#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly INTERVIEW_DIR="build/native-interview-manager-validation"
readonly INTERVIEW_MANAGER_BUILD_PATH="${INTERVIEW_MANAGER_BUILD_PATH:-${INTERVIEW_DIR}/derived}"
mkdir -p "$INTERVIEW_DIR"
ruby -ryaml -rjson - "$INTERVIEW_DIR" <<'RUBY'
root = Dir.pwd
folder = File.expand_path(ARGV[0])
spec = YAML.load_file('project.yml')
spec['name'] = 'NativeInterviewManagerValidation'
spec['packages'].each_value do |package|
  next unless package['path']
  package['path'] = ENV['STREAM_VENDOR_ROOT'] ? File.join(ENV['STREAM_VENDOR_ROOT'], File.basename(package['path'])) : File.join(root, package['path'])
end
spec['targets'].select! { |name, _| ['StreamCore', 'StreamMac'].include?(name) }
spec['schemes'] = {}
spec['targets'].each_value do |target|
  target['dependencies']&.reject! { |dependency| dependency['target'] && !spec['targets'].key?(dependency['target']) }
  target['sources'].map! { |source| source.is_a?(String) ? File.join(root, source) : source.merge('path' => File.join(root, source['path'])) }
  target.delete('entitlements'); target.delete('info')
end
target = spec['targets'].delete('StreamMac'); target['type'] = 'tool'
target['settings'] ||= {}; target['settings']['base'] ||= {}
# Shipping Restream credentials and shared provider vault already have explicit
# nil/no-network validation boundaries. Enable them before constructing Runtime.
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) STREAM_NATIVE_VALIDATION'
require File.join(root, 'scripts/guest_fixture_boundaries')
StreamGuestFixtureBoundaries.apply(spec['targets']['StreamCore'], target, root, folder)
# Runtime's default recorder stays in this owned fixture machine directory,
# just as in the existing actual Workspace lifecycle harness.
recording = File.join(folder, 'fixtures/Mac/RecordingController.swift')
abort 'Generated recording fixture boundary changed' unless File.exist?(recording)
recording_source = File.read(recording)
recording_default = 'defaultDirectory: URL? = nil'
abort 'Recording default directory boundary changed' unless recording_source.include?(recording_default)
recording_source.sub!(recording_default, 'defaultDirectory: URL? = GuestFixtureStorage.machineDirectory.appendingPathComponent("Recordings")')
File.write(recording, recording_source)
# Keep the shipping App root/MainWindow callbacks. Only the actual capture
# entry boundary is refused so this fixture never asks for operator devices.
source = File.read(File.join(root, 'StreamMac/StreamController.swift'))
preview = '    func startPreview() {'
abort 'Preview fixture boundary changed' unless source.include?(preview)
source.sub!(preview, "    func startPreview() {\n        InterviewWindowReceipts.previewSuppressed[ObjectIdentifier(self), default: 0] += 1\n        return")
controller = File.join(folder, 'fixtures/InterviewStreamController.swift')
File.write(controller, source)
target['sources'][0]['excludes'] << 'StreamController.swift'
target['sources'] << controller
app = File.read(File.join(root, 'StreamMac/StreamMacApp.swift'))
first = app.index('            MainWindowView(firstRunCompleted: $hasCompletedFirstRun)')
last = first && app.index("\n        }\n        .defaultSize", first)
abort 'Shipping App root boundary changed' unless first && last
content = app[first...last].strip
content.sub!('MainWindowView(firstRunCompleted: $hasCompletedFirstRun)', <<'SWIFT'.strip)
MainWindowView(firstRunCompleted: $hasCompletedFirstRun)
    .onAppear { InterviewWindowReceipts.appeared[ObjectIdentifier(observedRuntime), default: 0] += 1 }
    .onDisappear { InterviewWindowReceipts.disappeared[ObjectIdentifier(observedRuntime), default: 0] += 1 }
SWIFT
application_root = <<'SWIFT'
import SwiftUI
import StreamCore
@MainActor struct InterviewShippingApplicationRoot: View {
    @ObservedObject var workspace: StudioWorkspace
    @State private var hasCompletedFirstRun = true
    private var sceneStore: SceneStore { workspace.runtime.sceneStore }
    private var previewProgram: PreviewProgramModel { workspace.runtime.previewProgram }
    private var streamController: StreamController { workspace.runtime.controller }
    private var settingsSession: SettingsSession { workspace.runtime.settings }
    private var permissions: PermissionsManager { workspace.runtime.permissions }
    private var recorder: RecordingController { workspace.runtime.recorder }
    private var dispatcher: StudioCommandDispatcher { workspace.runtime.dispatcher }
    var body: some View {
        let observedRuntime = workspace.runtime
SWIFT
application_root += content + "\n.defaultAppStorage(GuestFixtureDefaults.value)\n    }\n}\n"
root_path = File.join(folder, 'fixtures/InterviewShippingApplicationRoot.swift')
File.write(root_path, application_root)
target['sources'] += [root_path, File.join(root, 'scripts/native_interview_manager_harness.swift'), File.join(root, 'scripts/program_recording_fixtures.swift')]
spec['targets']['NativeInterviewManagerHarness'] = target
spec['schemes']['NativeInterviewManagerHarness'] = {'build' => {'targets' => {'NativeInterviewManagerHarness' => 'all'}}}
File.write(File.join(folder, 'project.json'), JSON.pretty_generate(spec))
RUBY
xcodegen generate --spec "$INTERVIEW_DIR/project.json" --project "$INTERVIEW_DIR"
xcodebuild -resolvePackageDependencies -project "$INTERVIEW_DIR/NativeInterviewManagerValidation.xcodeproj" \
  -scheme NativeInterviewManagerHarness -derivedDataPath "$INTERVIEW_MANAGER_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$INTERVIEW_MANAGER_BUILD_PATH" --require-relay-policy
xcodebuild -project "$INTERVIEW_DIR/NativeInterviewManagerValidation.xcodeproj" -scheme NativeInterviewManagerHarness \
  -destination 'platform=macOS' -derivedDataPath "$INTERVIEW_MANAGER_BUILD_PATH" CODE_SIGNING_ALLOWED=NO build
readonly INTERVIEW_MANAGER_PRODUCTS="${INTERVIEW_MANAGER_BUILD_PATH:A}/Build/Products/Debug"
readonly INTERVIEW_RUN="$INTERVIEW_DIR/run-$(uuidgen)"
readonly INTERVIEW_NODE="${STREAM_INTERVIEW_NODE:-node}"
"$INTERVIEW_NODE" -e 'const [major,minor]=process.versions.node.split(".").map(Number); if(major!==24||minor<15) throw Error("Node >=24.15 <25 required")'
mkdir -p "$INTERVIEW_RUN"
chmod 700 "$INTERVIEW_RUN"
readonly INTERVIEW_RUN_ABSOLUTE="${INTERVIEW_RUN:A}"
readonly INTERVIEW_WORKER="${PWD:h}/workers/interviews"
if [[ ! -f "$INTERVIEW_WORKER/node_modules/wrangler/bin/wrangler.js" ]]; then
  print -u2 "Run npm ci in workers/interviews with the pinned Node24/npm12 dependencies."
  exit 1
fi
python3 - "$INTERVIEW_RUN" "$INTERVIEW_WORKER" <<'PY'
import json, pathlib, secrets, socket, sys
folder=pathlib.Path(sys.argv[1]).resolve()
worker=pathlib.Path(sys.argv[2]).resolve()
ports=[]
for _ in range(2):
    with socket.socket() as connection:
        connection.bind(('127.0.0.1',0))
        ports.append(connection.getsockname()[1])
token='native-fixture-'+secrets.token_hex(32)
config={
 'name':'native-interview-manager-validation',
 'main':str(worker/'src/index.ts'),
 'compatibility_date':'2026-10-02',
 'compatibility_flags':['nodejs_compat'],
 'durable_objects':{'bindings':[{'name':'ROOMS','class_name':'InterviewRoom'}]},
 'migrations':[{'tag':'v1','new_sqlite_classes':['InterviewRoom']}],
 'assets':{'directory':str(worker/'public'),'binding':'ASSETS','run_worker_first':True},
 'vars':{'OPERATOR_TOKEN':token,'ALLOWED_ORIGIN':'https://interviews.example.test','TURN_KEY_ID':''},
 'observability':{'enabled':False}
}
(folder/'wrangler.json').write_text(json.dumps(config))
(folder/'operator-token').write_text(token)
(folder/'ports').write_text('\n'.join(map(str,ports)))
for path in [folder/'wrangler.json',folder/'operator-token']:
    path.chmod(0o600)
PY
readonly INTERVIEW_PORT="$(sed -n '1p' "$INTERVIEW_RUN/ports")"
readonly INTERVIEW_INSPECTOR="$(sed -n '2p' "$INTERVIEW_RUN/ports")"
export STREAM_NATIVE_INTERVIEW_FIXTURE_TOKEN="$(<"$INTERVIEW_RUN/operator-token")"
(
  cd "$INTERVIEW_RUN_ABSOLUTE"
  exec "$INTERVIEW_NODE" "$INTERVIEW_WORKER/node_modules/wrangler/bin/wrangler.js" dev --local \
    --config "$INTERVIEW_RUN_ABSOLUTE/wrangler.json" --ip 127.0.0.1 --port "$INTERVIEW_PORT" \
    --inspector-port "$INTERVIEW_INSPECTOR" --persist-to "$INTERVIEW_RUN_ABSOLUTE/state" \
    --log-level warn --show-interactive-dev-session=false
) > "$INTERVIEW_RUN/worker.log" 2>&1 &
readonly INTERVIEW_WORKER_PID=$!
trap 'kill "$INTERVIEW_WORKER_PID" 2>/dev/null || true; wait "$INTERVIEW_WORKER_PID" 2>/dev/null || true; rm -f "$INTERVIEW_RUN/operator-token" "$INTERVIEW_RUN/wrangler.json"; rm -rf "$INTERVIEW_RUN/state" "$INTERVIEW_RUN/.wrangler"; unset STREAM_NATIVE_INTERVIEW_FIXTURE_TOKEN' EXIT
python3 - "$INTERVIEW_PORT" <<'PY'
import sys,time,urllib.request
url='http://127.0.0.1:'+sys.argv[1]+'/guest.html'
until=time.monotonic()+20
while time.monotonic()<until:
    try:
        with urllib.request.urlopen(url,timeout=1) as response:
            if response.status==200: break
    except Exception: time.sleep(.1)
else: raise SystemExit('Actual local interview Worker did not become ready')
PY
env DYLD_FRAMEWORK_PATH="$INTERVIEW_MANAGER_PRODUCTS" python3 - "$INTERVIEW_MANAGER_PRODUCTS/NativeInterviewManagerHarness" "http://127.0.0.1:$INTERVIEW_PORT" <<'PYRUN'
import subprocess,sys
try:
    raise SystemExit(subprocess.run(sys.argv[1:],timeout=90).returncode)
except subprocess.TimeoutExpired:
    print('FAIL: native interview manager fixture exceeded its 90-second bound',flush=True)
    raise SystemExit(1)
PYRUN
print "Local manager/service evidence: ${INTERVIEW_RUN:A}"
