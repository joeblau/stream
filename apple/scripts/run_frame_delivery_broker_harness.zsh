#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly BROKER_FIXTURE_DIR="${COMPOSITION_BROKER_FIXTURE_DIR:-build/frame-delivery-broker-validation}"
readonly BROKER_FIXTURE_BUILD_PATH="${FRAME_DELIVERY_BROKER_BUILD_PATH:-$BROKER_FIXTURE_DIR/derived}"
python3 scripts/prepare_frame_delivery_broker.py --output "$BROKER_FIXTURE_DIR" "$@"
xcodegen generate --spec "$BROKER_FIXTURE_DIR/project.json" --project "$BROKER_FIXTURE_DIR"
xcodebuild -jobs 2 -resolvePackageDependencies -project "$BROKER_FIXTURE_DIR/FrameDeliveryBroker.xcodeproj" \
    -scheme FrameDeliveryBrokerHarness -derivedDataPath "$BROKER_FIXTURE_BUILD_PATH"
python3 scripts/repair_desktop_transport_archives.py "$BROKER_FIXTURE_BUILD_PATH"
xcodebuild -jobs 2 -project "$BROKER_FIXTURE_DIR/FrameDeliveryBroker.xcodeproj" \
    -scheme FrameDeliveryBrokerHarness -destination 'platform=macOS' -derivedDataPath "$BROKER_FIXTURE_BUILD_PATH" \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2 -driver-batch-count 2' build
env DYLD_FRAMEWORK_PATH="${BROKER_FIXTURE_BUILD_PATH:A}/Build/Products/Debug" \
    python3 - "${BROKER_FIXTURE_BUILD_PATH:A}/Build/Products/Debug/FrameDeliveryBrokerHarness" "$BROKER_FIXTURE_DIR" "$@" <<'PY'
import json,pathlib,subprocess,sys,os,signal
binary=sys.argv[1];folder=pathlib.Path(sys.argv[2]);negative='--negative-control'in sys.argv[3:];sequence_negative='--sequence-negative-control'in sys.argv[3:]
command=[binary]+(['--sequence-negative-control'] if sequence_negative else ['--negative-control']if negative else[])
receipts=folder/('sequence-negative-observations' if sequence_negative else 'negative-observations'if negative else'production-observations');receipts.mkdir(exist_ok=True)
clock=folder/'clock-observations';clock.mkdir(exist_ok=True)
environment=dict(os.environ,FRAME_DELIVERY_RECEIPT_DIR=str(receipts.resolve()),COMPOSITION_CLOCK_RECEIPT_DIR=str(clock.resolve()))
p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,text=True,env=environment)
try:output,_=p.communicate(timeout=90)
finally:
 if p.poll()is None:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
(folder/('sequence-negative.log' if sequence_negative else 'negative.log'if negative else'production.log')).write_text(output)
if negative or sequence_negative:
 expected='Publication identity must preserve distinct old/new PTS and pixels when engine sequence resets' if sequence_negative else 'Escaped private raw holders must not exhaust the compositor source pool4 or lose healthy frames'
 assert p.returncode!=0 and expected in output,(p.returncode,output)
 print('EXPECTED NEGATIVE FAILURE:',p.returncode,expected)
else:
 print(output,end='');assert p.returncode==0,p.returncode
(folder/('sequence-negative-result.json' if sequence_negative else 'negative-result.json'if negative else'production-result.json')).write_text(json.dumps({'exitCode':p.returncode,'expectedFailure':negative or sequence_negative},indent=2)+'\n')
PY
