// Owned-profile test processes only. Chromium's OSCrypt GetKeychain selects
// MockKeychain for this public switch, avoiding login-Keychain permission waits:
// https://chromium.googlesource.com/chromium/src/+/refs/tags/143.0.7497.1/components/os_crypt/sync/os_crypt_mac.mm
// This changes neither the browser sandbox nor actual WebRTC/media APIs.
export function chromeFixtureCredentialArguments() {
  return process.platform === 'darwin' ? ['--use-mock-keychain'] : [];
}

export class ChromeFixtureDiagnostics {
  #started = performance.now();
  #pending = '';
  #state = {phase:'not-launched',product:'unknown',stderrBytes:0,stderrTruncated:false,
    gpuErrors:0,rendererErrors:0,sandboxErrors:0,stderrSites:{},targetCrashes:0,
    httpRequests:0,httpResponses:0,pid:null,exitCode:null,signal:null};
  observe(child) {
    this.#state.pid=child.pid??null;
    child.stderr?.on('data',chunk=>{
      const available=Math.max(0,262_144-this.#state.stderrBytes);
      this.#state.stderrBytes+=Math.min(available,chunk.length);
      if(chunk.length>available)this.#state.stderrTruncated=true;
      this.#pending+=chunk.subarray(0,available).toString('utf8');
      let newline;
      while((newline=this.#pending.indexOf('\n'))!==-1){
        const line=this.#pending.slice(0,newline);this.#pending=this.#pending.slice(newline+1);
        // Fixed counters and bounded internal source basenames only. Never
        // expose raw stderr, URLs/capabilities, profile paths, SDP or messages.
        if(/ERROR:.*gpu|GPU process exited/i.test(line))this.#state.gpuErrors++;
        if(/ERROR:.*render_process|renderer process.*crash/i.test(line))this.#state.rendererErrors++;
        if(/ERROR:.*sandbox/i.test(line))this.#state.sandboxErrors++;
        const site=line.match(/(?:ERROR|WARNING):(?:[a-z_]+\/)*([a-z_]{1,48}\.(?:cc|mm)):\d+\]/)?.[1];
        const sites=this.#state.stderrSites;
        if(site&&(Object.hasOwn(sites,site)||Object.keys(sites).length<12))sites[site]=(sites[site]??0)+1;
      }
      if(this.#pending.length>4096){this.#pending='';this.#state.stderrTruncated=true;}
    });
    child.once('exit',(code,signal)=>{
      this.#state.exitCode=Number.isInteger(code)?code:null;
      this.#state.signal=['SIGTERM','SIGKILL','SIGABRT','SIGSEGV','SIGTRAP'].includes(signal)?signal:signal?'other':null;
    });
  }
  request() { this.#state.httpRequests++; }
  response() { this.#state.httpResponses++; }
  event(method) { if(['Inspector.targetCrashed','Target.targetCrashed'].includes(method))this.#state.targetCrashes++; }
  version(product) { this.#state.product=/^(?:Headless)?Chrome\/\d+\.\d+\.\d+\.\d+$/.test(product)?product:'unknown'; }
  phase(phase) {
    const phases=['launch','debug-endpoint','debug-connected','browser-version','target-created','target-attached',
      'page-runtime-enabled','navigate','navigation-accepted','guest-ready'];
    this.#state.phase=phases.includes(phase)?phase:'unknown';this.#emit('phase');
  }
  timeout(method,pendingCommands) {
    this.#emit('timeout',{method:/^[A-Za-z]{1,24}\.[A-Za-z]{1,48}$/.test(method)?method:'unknown',
      pendingCommands:Number.isSafeInteger(pendingCommands)?pendingCommands:0});
  }
  #emit(event,extra={}) {
    console.log(`Chrome startup ${event}: ${JSON.stringify({...this.#state,
      mockKeychain:process.platform==='darwin',elapsedMilliseconds:Math.round(performance.now()-this.#started),...extra})}`);
  }
}
