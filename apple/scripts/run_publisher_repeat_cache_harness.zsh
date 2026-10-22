#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly CACHE_FIXTURE_DIR="${PUBLISHER_REPEAT_CACHE_DIR:-build/publisher-repeat-cache-validation}"
readonly CACHE_BUILD_PATH="${PUBLISHER_REPEAT_CACHE_BUILD_PATH:-$CACHE_FIXTURE_DIR/derived}"
for cache_mode in entry-negative future-negative positive; do
  readonly_variant="$CACHE_FIXTURE_DIR/$cache_mode"
  mkdir -p "$readonly_variant"
  python3 scripts/prepare_publisher_repeat_cache.py --mode "$cache_mode" --output "$readonly_variant"
  xcodegen generate --spec "$readonly_variant/project.json" --project "$readonly_variant"
  xcodebuild -jobs 2 -resolvePackageDependencies -project "$readonly_variant/PublisherRepeatCache.xcodeproj" \
    -scheme PublisherRepeatCacheHarness -derivedDataPath "$CACHE_BUILD_PATH"
  python3 scripts/repair_desktop_transport_archives.py "$CACHE_BUILD_PATH"
  xcodebuild -jobs 2 -project "$readonly_variant/PublisherRepeatCache.xcodeproj" \
    -scheme PublisherRepeatCacheHarness -destination 'platform=macOS' -derivedDataPath "$CACHE_BUILD_PATH" \
    CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j2' build
  cp "$CACHE_BUILD_PATH/Build/Products/Debug/PublisherRepeatCacheHarness" "$readonly_variant/compiled-harness"
  env DYLD_FRAMEWORK_PATH="${CACHE_BUILD_PATH:A}/Build/Products/Debug" \
    python3 - "${readonly_variant:A}" "$cache_mode" <<'PY'
import json,os,pathlib,signal,subprocess,sys
folder=pathlib.Path(sys.argv[1]);mode=sys.argv[2]
observations=folder/'observations';observations.mkdir(exist_ok=True)
env=dict(os.environ,PUBLISHER_REPEAT_RECEIPT_DIR=str(observations))
cases=[('all',[])]if mode=='positive'else[(name,[name,mode.split('-')[0]])for name in ['rtmp','session']]
results=[]
for name,args in cases:
 p=subprocess.Popen([str(folder/'compiled-harness')]+args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try:output,_=p.communicate(timeout=30)
 finally:
  if p.poll()is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=3)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 (folder/(name+'.log')).write_text(output)
 if mode=='positive':
  print(output,end='');assert p.returncode==0,(p.returncode,output)
 else:
  expected='Program entry must release legacy repeat buffer before mixer configuration returns'if mode=='entry-negative'else'Program video must not retain repeat source buffer'
  assert p.returncode!=0 and expected in output,(name,p.returncode,output)
  print('EXPECTED NEGATIVE FAILURE:',name,mode,p.returncode,expected)
 results.append({'case':name,'mode':mode,'exitCode':p.returncode})
(folder/'result.json').write_text(json.dumps(results,indent=2)+'\n')
PY
done
