#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly INTERVIEW_DIR="build/native-interview-validation"
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
 'name':'native-interview-control-validation',
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
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  StreamMac/GuestMediaReceipts.swift StreamMac/NativeInterviewTypes.swift \
  StreamMac/NativeInterviewServiceClient.swift StreamMac/NativeInterviewSession.swift \
  scripts/native_interview_control_harness.swift -o "$INTERVIEW_DIR/native-interview-control"
"$INTERVIEW_DIR/native-interview-control" "http://127.0.0.1:$INTERVIEW_PORT"
print "Local service evidence: ${INTERVIEW_RUN:A}"
