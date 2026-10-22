#!/usr/bin/env python3
"""Build/run one owned synthetic guest ISO tool; retain every outcome."""
import argparse,hashlib,json,os,pathlib,shutil,subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--derived',type=pathlib.Path,required=True);p.add_argument('--core-framework-dir',type=pathlib.Path,required=True);a=p.parse_args();apple=pathlib.Path(__file__).resolve().parents[1]
output=a.output.resolve();derived=a.derived.resolve();output.mkdir(parents=True,exist_ok=False)
if not derived.is_relative_to((apple/'build').resolve()):raise SystemExit('Derived cache must be owned under this worktree apple/build')
r={'scope':'Owned actual guest Factory/ISO worker/writer/video decoder, no capture/RTC/audio graph'};phase='prepare'
sha=lambda v:hashlib.sha256(v.read_bytes()).hexdigest()
try:
    core=a.core_framework_dir.resolve()/'StreamCore.framework';copied=derived/'Build/Products/Debug/StreamCore.framework'
    if copied.resolve()==core.resolve():raise SystemExit('Cannot mutate immutable Core')
    if copied.exists():shutil.rmtree(copied)
    shutil.copytree(core,copied,symlinks=True);r['copiedCoreSHA256']=sha(copied/'StreamCore')
    subprocess.run(['python3',str(apple/'scripts/prepare_recording_guest_iso_private.py'),'--output',str(output),'--core-framework-dir',str(a.core_framework_dir)],check=True,timeout=30)
    subprocess.run(['xcodegen','generate','--spec',str(output/'project.json'),'--project',str(output)],check=True,timeout=30)
    phase='compile'
    subprocess.run(['xcodebuild','-jobs','2','-project',str(output/'RecordingGuestISOPrivate.xcodeproj'),'-scheme','RecordingGuestISOPrivateHarness','-destination','platform=macOS,arch=arm64','-derivedDataPath',str(derived),'-skipPackageUpdates','-disableAutomaticPackageResolution','CODE_SIGNING_ALLOWED=NO','OTHER_SWIFT_FLAGS=$(inherited) -j2 -driver-batch-count 2','build'],check=True,timeout=600)
    products=derived/'Build/Products/Debug';executable=output/'RecordingGuestISOPrivateHarness';shutil.copy2(products/executable.name,executable);r['executableSHA256']=sha(executable)
    phase='runtime';env=dict(os.environ,DYLD_FRAMEWORK_PATH=str(a.core_framework_dir.resolve())+':'+str(products)+':'+str(products/'PackageFrameworks'))
    subprocess.run([str(executable),str(output/'media')],check=True,timeout=120,env=env)
    r.update(result='PASS',observationsSHA256=sha(output/'media/observations.json'))
except Exception as e:
    r.update(result='FAIL',phase=phase,failureType=type(e).__name__)
    if isinstance(e,subprocess.CalledProcessError):r['processReturnCode']=e.returncode
    if isinstance(e,subprocess.TimeoutExpired):r['timeoutSeconds']=e.timeout
    raise
finally:
    r['runnerSHA256']=sha(pathlib.Path(__file__).resolve());(output/'result.json').write_text(json.dumps(r,indent=2,sort_keys=True)+'\n')
