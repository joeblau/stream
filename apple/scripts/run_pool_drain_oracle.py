#!/usr/bin/env python3
"""Manual bounded synthetic Core Video pool-drain alias experiment, not a benchmark."""
import argparse,hashlib,json,os,pathlib,signal,subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=pathlib.Path)
a=parser.parse_args();root=pathlib.Path(__file__).resolve().parents[1]
p=(a.output or root/'build/pool-drain-oracle').resolve();p.mkdir(parents=True,exist_ok=True)
source=root/'scripts/pool_drain_oracle.m';binary=p/'pool-drain-oracle';receipt=p/'pool-drain-oracle.json'
command=['xcrun','clang','-fno-objc-arc','-fblocks','-O0','-g',str(source),'-o',str(binary)]
for framework in ['Foundation','CoreVideo','CoreMedia','IOSurface','Metal','CoreImage','CoreGraphics']:command+=['-framework',framework]
compile_result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60);(p/'compile.log').write_text(compile_result.stdout)
print('COMPILE EXIT',compile_result.returncode,flush=True)
if compile_result.returncode:print(compile_result.stdout);raise SystemExit(compile_result.returncode)
process=subprocess.Popen([str(binary),str(receipt)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
try:output,_=process.communicate(timeout=30)
except subprocess.TimeoutExpired:
 os.killpg(process.pid,signal.SIGTERM)
 try:output,_=process.communicate(timeout=3)
 except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);output,_=process.communicate()
 (p/'runtime.log').write_text(output);print(output);raise SystemExit('Owned30seconddeadline exceeded; no repeat')
(p/'runtime.log').write_text(output);print(output,end='')
sha=lambda x:hashlib.sha256(x.read_bytes()).hexdigest()
metadata={'baseCommit':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'compileCommand':command,'processExit':process.returncode,'sourceSHA256':sha(source),'binarySHA256':sha(binary),'resultSHA256':sha(receipt)if receipt.exists()else None,'runtimeLogSHA256':sha(p/'runtime.log'),'clang':subprocess.check_output(['xcrun','clang','--version'],text=True).strip(),'os':subprocess.check_output(['sw_vers'],text=True).strip(),'model':subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(),'scope':'Single fixed owned16x16synthetic allocation-drain oracle experiment. One compiler process; no Swift compile, fullgraph, capture, codecs, media or capacity measurement.'}
(p/'experiment-source.json').write_text(json.dumps(metadata,indent=2)+'\n')
raise SystemExit(process.returncode)
