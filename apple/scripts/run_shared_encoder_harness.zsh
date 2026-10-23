#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SHARED_ENCODER_DIR="build/shared-encoder-validation"
readonly SHARED_ENCODER_BUILD_PATH="${SHARED_ENCODER_BUILD_PATH:-$SHARED_ENCODER_DIR/derived}"
mkdir -p "$SHARED_ENCODER_DIR"
python3 scripts/prepare_shared_encoder_stop_diagnostics.py "$SHARED_ENCODER_DIR"
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
target['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) STREAM_NATIVE_VALIDATION STREAM_SHARED_ENCODER_STOP_DIAGNOSTICS'
target['sources'][0]={'path'=>File.join(root,'StreamMac'),'excludes'=>['StreamMacApp.swift','DestinationOutputController.swift']}
target['sources'] << File.join(root,folder,'stop-diagnostics/DestinationOutputController.swift')
target['sources'] << File.join(root,'scripts/SharedEncoderStopDiagnostics.swift')
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
import datetime,json,os,pathlib,signal,subprocess,sys,threading,time,uuid
root=pathlib.Path(os.environ.get('STREAM_TRANSPORT_ARTIFACT_ROOT','build/shared-encoder-validation/artifacts')).resolve()
root.mkdir(parents=True,exist_ok=True)
invocation=root/('invocation-'+str(uuid.uuid4()))
invocation.mkdir()
environment=dict(os.environ,STREAM_TRANSPORT_ARTIFACT_ROOT=str(invocation))
log=(invocation/'stdout-stderr.log').open('xb',buffering=0)
started=time.monotonic()
receipt={'arguments':sys.argv[2:],'deadlineSeconds':90,
         'startedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
         'stdoutStderr':str(invocation/'stdout-stderr.log'),'timedOut':False}
def persist():
    temporary=invocation/'invocation.json.tmp'
    temporary.write_text(json.dumps(receipt,indent=2)+'\n')
    temporary.replace(invocation/'invocation.json')
log.write(('Fixture invocation artifacts: '+str(invocation)+'\n').encode())
persist()
# Native output goes directly to the owned file. A slow/broken CI reader
# can delay the optional live echo, never the child or durable capture.
try:
    process=subprocess.Popen(sys.argv[1:],start_new_session=True,stdout=log,stderr=subprocess.STDOUT,env=environment)
except Exception as error:
    receipt['spawnError']=type(error).__name__
    receipt['launcherExitCode']=1
    persist()
    log.close()
    raise
spawned=time.monotonic()
receipt['pid']=process.pid
receipt['spawnedElapsedSeconds']=spawned-started
receipt['stdoutCapture']='direct-owned-file'
persist()
finished=threading.Event()
def echo():
    try:
        with (invocation/'stdout-stderr.log').open('rb',buffering=0) as source:
            while True:
                data=source.read(65536)
                if data:
                    remaining=memoryview(data)
                    while remaining:
                        written=os.write(sys.stdout.fileno(),remaining)
                        if written <= 0: raise OSError('Live echo made no progress')
                        remaining=remaining[written:]
                elif finished.is_set():
                    break
                else:
                    finished.wait(0.02)
    except (BrokenPipeError,OSError) as error:
        receipt['liveEchoError']=type(error).__name__
reader=threading.Thread(target=echo,daemon=True)
reader.start()
exit_code=1
try:
    # Keep one absolute 90-second native budget; diagnostics never reset it.
    exit_code=process.wait(timeout=max(0,90-(time.monotonic()-spawned)))
except subprocess.TimeoutExpired:
    receipt['timedOut']=True
    receipt['timeoutElapsedSeconds']=time.monotonic()-spawned
    persist()
    # Only this generated fixture and its owned FFmpeg receivers share the group.
    os.killpg(process.pid,signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        process.wait()
    log.write(('FAIL: shared encoder fixture exceeded90s; durable invocation artifacts: '+str(invocation)+'\n').encode())
finally:
    log.close()
    finished.set()
    reader.join(timeout=1)
    receipt['liveEchoComplete']=not reader.is_alive()
    receipt['stdoutBytes']=(invocation/'stdout-stderr.log').stat().st_size
    receipt['processExitCode']=process.returncode
    receipt['launcherExitCode']=exit_code
    receipt['elapsedSeconds']=time.monotonic()-started
    receipt['nativeGuardElapsedSeconds']=time.monotonic()-spawned
    last=[]
    for path in invocation.glob('stream-shared-encoder-*/phase-last.json'):
        try: last.append({'path':str(path),'value':json.loads(path.read_text())})
        except (OSError,ValueError): last.append({'path':str(path),'unreadable':True})
    receipt['lastPhases']=last
    persist()
raise SystemExit(exit_code)
PYTHON
}
if (( $# > 0 )); then
  run_shared_encoder_fixture "$@"
  exit
fi
run_shared_encoder_fixture
run_shared_encoder_fixture --software
