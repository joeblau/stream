#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly MAILBOX_FIXTURE_DIR="${COMPOSITION_MAILBOX_FIXTURE_DIR:-build/composition-mailbox-retirement-validation}"
readonly MAILBOX_FIXTURE_BUILD_PATH="${COMPOSITION_MAILBOX_BUILD_PATH:-$MAILBOX_FIXTURE_DIR/derived}"
python3 scripts/prepare_composition_mailbox_retirement.py --output "$MAILBOX_FIXTURE_DIR" "$@"
xcodegen generate --spec "$MAILBOX_FIXTURE_DIR/project.json" --project "$MAILBOX_FIXTURE_DIR"
xcodebuild -jobs 2 -resolvePackageDependencies -project "$MAILBOX_FIXTURE_DIR/CompositionMailboxRetirement.xcodeproj" \
    -scheme CompositionMailboxRetirementHarness -derivedDataPath "$MAILBOX_FIXTURE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$MAILBOX_FIXTURE_BUILD_PATH"
xcodebuild -jobs 2 -project "$MAILBOX_FIXTURE_DIR/CompositionMailboxRetirement.xcodeproj" \
    -scheme CompositionMailboxRetirementHarness -destination 'platform=macOS' -derivedDataPath "$MAILBOX_FIXTURE_BUILD_PATH" \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2 -driver-batch-count 2' build
env DYLD_FRAMEWORK_PATH="${MAILBOX_FIXTURE_BUILD_PATH:A}/Build/Products/Debug" \
    python3 - "${MAILBOX_FIXTURE_BUILD_PATH:A}/Build/Products/Debug/CompositionMailboxRetirementHarness" "$MAILBOX_FIXTURE_DIR" "$@" <<'PY'
import json,pathlib,subprocess,sys,os,signal
binary=sys.argv[1];folder=pathlib.Path(sys.argv[2]);negative='--negative-control'in sys.argv[3:]
command=[binary]+(['--negative-control']if negative else[])
receipts=folder/('negative-observations'if negative else'production-observations');receipts.mkdir(exist_ok=True)
clock=folder/'clock-observations';clock.mkdir(exist_ok=True)
environment=dict(os.environ,COMPOSITION_MAILBOX_RECEIPT_DIR=str(receipts.resolve()),COMPOSITION_CLOCK_RECEIPT_DIR=str(clock.resolve()))
p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,text=True,env=environment)
try:output,_=p.communicate(timeout=45)
finally:
 if p.poll()is None:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
(folder/('negative.log'if negative else'production.log')).write_text(output)
if negative:
 expected='Retiring pending mailbox ownership must restore healthy rendering before active callbacks return'
 assert p.returncode!=0 and expected in output,(p.returncode,output)
 print('EXPECTED NEGATIVE FAILURE:',p.returncode,expected)
else:
 print(output,end='');assert p.returncode==0,p.returncode
(folder/('negative-result.json'if negative else'production-result.json')).write_text(json.dumps({'exitCode':p.returncode,'expectedFailure':negative},indent=2)+'\n')
PY
