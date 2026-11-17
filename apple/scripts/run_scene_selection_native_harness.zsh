#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SCENE_SEMANTICS_DIR="${SCENE_SEMANTICS_DIR:-build/scene-selection-semantics}"
python3 - "$SCENE_SEMANTICS_DIR" "$@" <<'PY'
from pathlib import Path
import hashlib,json,os,plistlib,signal,subprocess,sys,time,uuid
from urllib.parse import unquote,urlsplit
root=Path.cwd();output=Path(sys.argv[1]).resolve()
owned_launchservices='--owned-launchservices' in sys.argv[2:]
output.mkdir(parents=True,exist_ok=False,mode=0o700 if owned_launchservices else 0o777)
sources=output/'sources';sources.mkdir(mode=0o700 if owned_launchservices else 0o777);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
receipt={'scope':'Actual stock SwiftUI and AppKit baselines before production SceneSelectionButton; public owned-only ObjC/C AX, no global input/settings/TCC/VoiceOver or device graph','sources':{},'checks':[]}
for name in ['StreamMac/SceneSelectionButton.swift','scripts/scene_selection_native_harness.swift','scripts/scene_selection_ax_bridge.m','scripts/scene_selection_ax_bridge.h','scripts/run_scene_selection_native_harness.zsh']:
    p=root/name;target=sources/p.name;target.write_bytes(p.read_bytes());receipt['sources'][str(p)]={'snapshot':str(target),'sha256':sha(target)}
arguments=sys.argv[2:]
arguments=[x for x in arguments if x!='--owned-launchservices']
bundled='--owned-bundle' in arguments
arguments=[x for x in arguments if x!='--owned-bundle']
executable=output/'harness'
if bundled:
    bundle=output/'OwnedSceneSemanticBaseline.app';(bundle/'Contents/MacOS').mkdir(parents=True)
    executable=bundle/'Contents/MacOS/harness'
    info={'CFBundleExecutable':'harness','CFBundleIdentifier':'com.stream.owned.scene-semantic-baseline.wave18','CFBundleName':'OwnedSceneSemanticBaseline','CFBundleDisplayName':'Owned Scene Semantic Baseline','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info,sort_keys=True));receipt['ownedBundleInfo']=info
commands=[('bridge',['xcrun','clang','-fobjc-arc','-c',str(sources/'scene_selection_ax_bridge.m'),'-o',str(output/'bridge.o')],120),
('swift',['xcrun','swiftc','-j2','-swift-version','6','-strict-concurrency=complete','-parse-as-library','-import-objc-header',str(sources/'scene_selection_ax_bridge.h'),str(sources/'SceneSelectionButton.swift'),str(sources/'scene_selection_native_harness.swift'),str(output/'bridge.o'),'-o',str(executable)],120),
('runtime',[str(executable)]+arguments,30)]
if owned_launchservices:
    # This opt-in has the same actual hosted guards as the app's keyboard setup.
    # It cannot enable hosted activation for the historical direct mode.
    refusal=None
    if (sys.platform!='darwin' or os.environ.get('GITHUB_ACTIONS')!='true'
        or os.environ.get('RUNNER_ENVIRONMENT')!='self-hosted' or not bundled
        or arguments!=['--public-cax-child','--owned-keyboard-setup']):
        refusal='Owned Launch Services requires the exact owned bundle, self-hosted macOS and original own-parent C AX/keyboard flags'
    clock=time.get_clock_info('monotonic')
    if sys.version_info<(3,10) or 'mach_absolute_time' not in clock.implementation:
        refusal='Owned Launch Services requires the documented shared macOS Mach uptime clock (Python 3.10+)'
    if refusal:
        receipt['launchServicesRefusal']=refusal
        receipt['artifacts']={str(p):sha(p) for p in output.rglob('*') if p.is_file()}
        (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print('UNQUALIFIED: '+refusal,flush=True)
        sys.exit(77)
    helper=root/'scripts/scene_selection_owned_launcher.swift'
    helper_snapshot=sources/helper.name
    try:helper_snapshot.write_bytes(helper.read_bytes())
    except OSError as failure:
        receipt['launchServicesSetupFailure']=str(failure)
        receipt['artifacts']={str(p):sha(p) for p in output.rglob('*') if p.is_file()}
        (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        sys.exit(1)
    receipt['sources'][str(helper)]={'snapshot':str(helper_snapshot),'sha256':sha(helper_snapshot)}
    # Bind the exact original five immutable snapshots, including the runner.
    source_manifest={str(Path(p).relative_to(root)):entry['sha256'] for p,entry in receipt['sources'].items() if Path(p)!=helper}
    source_digest=hashlib.sha256(json.dumps(source_manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    launcher=output/'owned-scene-launcher'
    commands.insert(2,('launcher-swift',['xcrun','swiftc','-j2','-swift-version','6','-strict-concurrency=complete','-parse-as-library',str(helper_snapshot),'-o',str(launcher)],120))
    receipt['launchServices']={'sourceManifest':source_manifest,'sourceSHA256':source_digest,
        'clockImplementation':clock.implementation,'clockResolutionSeconds':clock.resolution,
        'clockReferences':['https://docs.python.org/3/library/time.html#time.monotonic',
            'https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/swift/Time.swift'],
        'totalRuntimeSeconds':30,'helperBudgetSeconds':27,
        'statusScope':'helper exit alone is insufficient; require monitored native normal exit and matching app terminal code 0/1/77; unknown is unqualified'}

    def bounded_json(path):
        if path.is_symlink() or not path.is_file():raise ValueError('Missing regular owned receipt: '+path.name)
        with path.open('rb') as f:data=f.read(65537)
        if len(data)>65536:raise ValueError('Oversized owned receipt: '+path.name)
        value=json.loads(data)
        if not isinstance(value,dict):raise ValueError('Malformed owned receipt: '+path.name)
        return value

    def owned_url(value,expected):
        if not isinstance(value,str):return False
        parsed=urlsplit(value)
        return (parsed.scheme=='file' and not parsed.netloc and not parsed.query and not parsed.fragment
            and Path(unquote(parsed.path)).resolve()==expected.resolve())

    def launch_owned():
        # Source validation precedes launch; compiled snapshots never change.
        try:
            if any(sha(Path(p))!=entry['sha256'] or sha(Path(entry['snapshot']))!=entry['sha256'] for p,entry in receipt['sources'].items()):
                raise ValueError('Owned launch source bytes changed after snapshot')
        except (OSError,ValueError) as failure:
            receipt['checks'].append({'label':'runtime','exit':77,'nativeResultQualified':False,'failure':str(failure)})
            return 77
        nonce=str(uuid.uuid4());binary_digest=sha(executable)
        start=time.monotonic_ns();deadline=start+30_000_000_000;helper_deadline=start+27_000_000_000
        deadline_string=str(deadline)
        command=[str(launcher),'--app',str(bundle),'--artifacts',str(output),'--nonce',nonce,
            '--source-sha256',source_digest,'--binary-sha256',binary_digest,
            '--deadline-uptime-ns',deadline_string,'--helper-deadline-uptime-ns',str(helper_deadline),'--']+arguments
        observation={'label':'runtime','command':command,'timeoutSeconds':30,'nonce':nonce,
            'sourceSHA256':source_digest,'binarySHA256':binary_digest,'launcherSHA256':sha(launcher),
            'startUptimeNanoseconds':str(start),'deadlineUptimeNanoseconds':deadline_string,
            'helperDeadlineUptimeNanoseconds':str(helper_deadline),'nativePassVerified':False}
        log=output/'runtime.log';process=None;status=77
        try:
            # Direct file capture avoids a surviving app/child keeping a pipe open.
            with log.open('xb') as handle:
                process=subprocess.Popen(command,stdout=handle,stderr=subprocess.STDOUT,start_new_session=True)
                observation['pid']=process.pid
                try:
                    # Reserve the final second of the original budget for killing
                    # and reaping this launcher. Its own app cleanup ends by 27s.
                    process.wait(timeout=max(0,(deadline-1_000_000_000-time.monotonic_ns())/1e9))
                except subprocess.TimeoutExpired:
                    observation['outerTimeout']=True
                    try:os.killpg(process.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                    try:process.wait(timeout=max(0,(deadline-time.monotonic_ns())/1e9))
                    except subprocess.TimeoutExpired:observation['launcherReapUnconfirmed']=True
            observation['exit']=process.poll()
            observation['launcherReaped']=process.poll() is not None
            observation['elapsedSeconds']=(time.monotonic_ns()-start)/1e9
            if process.returncode not in (0,1,77):return 77
            if time.monotonic_ns()>deadline:raise ValueError('Original whole-launch deadline exceeded')
            helper_receipt=bounded_json(output/'launcher-receipt.json')
            terminal=bounded_json(output/('owned-launch-'+nonce+'-terminal.json'))
            if type(helper_receipt.get('schema')) is not int or type(terminal.get('schema')) is not int:
                raise ValueError('Owned launcher/app receipt schema mismatch')
            identity={'schema':1,'nonce':nonce,'sourceSHA256':source_digest,'binarySHA256':binary_digest,
                'deadlineUptimeNanoseconds':deadline_string}
            if any(helper_receipt.get(k)!=v or terminal.get(k)!=v for k,v in identity.items()):
                raise ValueError('Owned launcher/app receipt identity mismatch')
            if helper_receipt.get('helperDeadlineUptimeNanoseconds')!=str(helper_deadline) or terminal.get('phase')!='oracle':
                raise ValueError('Owned helper deadline or app terminal phase mismatch')
            native_pid=helper_receipt.get('pid')
            if type(native_pid) is not int or native_pid<=0 or terminal.get('pid')!=native_pid:
                raise ValueError('Owned launcher/app PID mismatch')
            for key,path in [('bundleURL',bundle),('executableURL',executable)]:
                if helper_receipt.get(key)!=terminal.get(key) or not owned_url(helper_receipt.get(key),path):
                    raise ValueError('Owned launcher/app URL mismatch')
            native_log=output/('owned-launch-runtime-'+nonce+'.log')
            if (helper_receipt.get('runtimeLogURL')!=terminal.get('runtimeLogURL')
                or not owned_url(helper_receipt.get('runtimeLogURL'),native_log)
                or native_log.is_symlink() or not native_log.is_file()):
                raise ValueError('Owned native app log identity mismatch')
            native_status=helper_receipt.get('observedExitStatus')
            if (type(native_status) is not int or native_status not in (0,1,77)
                or helper_receipt.get('verifiedSuccess') is not (native_status==0)
                or helper_receipt.get('resultVerified') is not True or helper_receipt.get('terminalVerified') is not True
                or helper_receipt.get('cleanupRequested') is not False
                or helper_receipt.get('statusObserved') is not True
                or helper_receipt.get('ownershipVerified') is not True or helper_receipt.get('terminated') is not True
                or helper_receipt.get('observedExitReason')!='normal'
                or type(terminal.get('oracleExitCode')) is not int or terminal['oracleExitCode']!=native_status
                or process.returncode!=native_status):
                raise ValueError('Owned native exit/terminal oracle not verified')
            observation['nativePID']=native_pid;observation['nativePassVerified']=native_status==0
            observation['nativeResultQualified']=True;observation['qualifiedOracleExitCode']=native_status
            observation['nativeRuntimeLog']=str(native_log);observation['nativeRuntimeLogSHA256']=sha(native_log)
            observation['launcherReceiptSHA256']=sha(output/'launcher-receipt.json')
            observation['terminalReceiptSHA256']=sha(output/('owned-launch-'+nonce+'-terminal.json'))
            status=native_status
        except Exception as failure:
            observation['failure']=str(failure);status=77
        finally:
            observation['log']=str(log)
            if log.exists():observation['sha256']=sha(log)
            observation['wholeLaunchElapsedSeconds']=(time.monotonic_ns()-start)/1e9
            observation['withinOriginalDeadline']=time.monotonic_ns()<=deadline
            if observation.get('nativeResultQualified') and not observation['withinOriginalDeadline']:
                observation['nativeExitAndOracleVerified']=True
                observation['nativeResultQualified']=False
                observation['nativePassVerified']=False
                observation['failure']='Original whole-launch deadline exceeded during result verification'
                status=77
            receipt['checks'].append(observation)
            # Durable log only: a blocked CI stdout reader cannot extend this
            # opt-in runtime or hide a tail after its recorded elapsed time.
        return status
status=1
try:
    for label,command,timeout in commands:
        if owned_launchservices and label=='runtime':
            status=launch_owned()
            if status!=0:break
            continue
        process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True,env=dict(os.environ,STREAM_SCENE_SEMANTIC_ARTIFACTS=str(output)))
        stdout,stderr=process.communicate(timeout=timeout)
        log=output/(label+'.log');log.write_text(stdout+stderr);print(log.read_text(),end='',flush=True)
        receipt['checks'].append({'label':label,'command':command,'pid':process.pid,'exit':process.returncode,'log':str(log),'sha256':sha(log)})
        status=process.returncode
        if status!=0:break
except subprocess.TimeoutExpired as failure:
    status=1
    try:os.killpg(process.pid,signal.SIGKILL)
    except ProcessLookupError:pass
    stdout,stderr=process.communicate();log=output/(label+'.log');log.write_text(stdout+stderr)
    receipt['checks'].append({'label':label,'command':command,'exit':None,'timeoutSeconds':failure.timeout,'log':str(log),'sha256':sha(log)})
finally:
    receipt['artifacts']={str(p):sha(p) for p in output.rglob('*') if p.is_file()}
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
sys.exit(status)
PY
