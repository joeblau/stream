#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly SCENE_SEMANTICS_DIR="${SCENE_SEMANTICS_DIR:-build/scene-selection-semantics}"
python3 - "$SCENE_SEMANTICS_DIR" "$@" <<'PY'
from pathlib import Path
import hashlib,json,os,plistlib,signal,subprocess,sys
root=Path.cwd();output=Path(sys.argv[1]).resolve();output.mkdir(parents=True,exist_ok=False)
sources=output/'sources';sources.mkdir();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
receipt={'scope':'Actual stock SwiftUI and AppKit baselines before production SceneSelectionButton; public owned-only ObjC/C AX, no global input/settings/TCC/VoiceOver or device graph','sources':{},'checks':[]}
for name in ['StreamMac/SceneSelectionButton.swift','scripts/scene_selection_native_harness.swift','scripts/scene_selection_ax_bridge.m','scripts/scene_selection_ax_bridge.h','scripts/run_scene_selection_native_harness.zsh']:
    p=root/name;target=sources/p.name;target.write_bytes(p.read_bytes());receipt['sources'][str(p)]={'snapshot':str(target),'sha256':sha(target)}
arguments=sys.argv[2:];bundled='--owned-bundle' in arguments
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
status=1
try:
    for label,command,timeout in commands:
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
