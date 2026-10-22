#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CLOCK_FIXTURE_DIR="${COMPOSITION_CLOCK_FIXTURE_DIR:-build/composition-clock-authority-validation}"
readonly CLOCK_FIXTURE_BUILD_PATH="${COMPOSITION_CLOCK_BUILD_PATH:-$CLOCK_FIXTURE_DIR/derived}"
python3 scripts/prepare_composition_clock_authority.py --output "$CLOCK_FIXTURE_DIR" "$@"
xcodegen generate --spec "$CLOCK_FIXTURE_DIR/project.json" --project "$CLOCK_FIXTURE_DIR"
xcodebuild -jobs 2 -resolvePackageDependencies -project "$CLOCK_FIXTURE_DIR/CompositionClockAuthority.xcodeproj" \
    -scheme CompositionClockAuthorityHarness -derivedDataPath "$CLOCK_FIXTURE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$CLOCK_FIXTURE_BUILD_PATH"
xcodebuild -jobs 2 -project "$CLOCK_FIXTURE_DIR/CompositionClockAuthority.xcodeproj" \
    -scheme CompositionClockAuthorityHarness -destination 'platform=macOS' -derivedDataPath "$CLOCK_FIXTURE_BUILD_PATH" \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2 -driver-batch-count 2' build
env DYLD_FRAMEWORK_PATH="${CLOCK_FIXTURE_BUILD_PATH:A}/Build/Products/Debug" \
    python3 - "${CLOCK_FIXTURE_BUILD_PATH:A}/Build/Products/Debug/CompositionClockAuthorityHarness" "$CLOCK_FIXTURE_DIR" "$@" <<'PY'
import json,pathlib,subprocess,sys,os,signal
binary=sys.argv[1];folder=pathlib.Path(sys.argv[2]);negative='--negative-control'in sys.argv[3:]
expected={'stopped-tick':'Stopped clock changed metrics after cancellation','restarted-tick':'Retired clock changed replacement metrics','reconfigure':'Retired clock changed replacement metrics','stopped-missed':'Retired clock changed missed-deadline metrics','restarted-missed':'Retired clock changed missed-deadline metrics'}
results=[]
for name in (list(expected)if negative else['all']):
 command=[binary]+([name]if name!='all'else[])
 receipts=folder/('negative-observations'if negative else'production-observations');receipts.mkdir(exist_ok=True)
 environment=dict(os.environ,COMPOSITION_CLOCK_RECEIPT_DIR=str(receipts.resolve()))
 p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,text=True,env=environment)
 try:output,_=p.communicate(timeout=30)
 finally:
  if p.poll()is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=3)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 (folder/f'{"negative"if negative else"production"}-{name}.log').write_text(output)
 if negative:
  assert p.returncode!=0 and expected[name]in output,(name,p.returncode,output)
  print('EXPECTED NEGATIVE FAILURE:',name,'exit',p.returncode,expected[name])
 else:
  print(output,end='');assert p.returncode==0,(name,p.returncode)
 results.append({'case':name,'exitCode':p.returncode,'expectedFailure':negative})
(folder/('negative-results.json'if negative else'production-results.json')).write_text(json.dumps(results,indent=2)+'\n')
PY
