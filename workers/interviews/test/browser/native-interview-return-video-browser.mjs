// Actual local Worker control + owned Coturn relay + shipping native session,
// receiver adapter and leased sink. Generated capture inputs only, no devices.
import assert from 'node:assert/strict';
import {randomBytes,createHash} from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {WebSocket} from 'ws';
import {analyzeReturnAV} from './native-return-video-analysis.mjs';
import {chromeFixtureExecutable, chromeFixtureCredentialArguments, ChromeFixtureDiagnostics} from './chrome-fixture.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const startup=new ChromeFixtureDiagnostics();
async function wait(label,predicate,timeout=15_000){const end=Date.now()+timeout;while(Date.now()<end){const value=await predicate();if(value)return value;await pause(50);}throw new Error(`Bounded fixture timeout: ${label}`);}
async function port(){const server=net.createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const value=server.address().port;await new Promise(resolve=>server.close(resolve));return value;}
const workerRoot=fileURLToPath(new URL('../../',import.meta.url));
const cli=process.env.NATIVE_INTERVIEW_RETURN_AUDIO_CLI, turnserver=process.env.STREAM_INTERVIEW_TURN_SERVER;
assert(cli&&path.isAbsolute(cli)&&turnserver&&path.isAbsolute(turnserver),'Set absolute owned native CLI and pinned Coturn executable paths');
await fs.access(cli,fs.constants.X_OK);await fs.access(turnserver,fs.constants.X_OK);
const owned=await fs.mkdtemp(path.join(os.tmpdir(),'stream-native-return-relay-'));await fs.chmod(owned,0o700);
let worker,turn,native,chrome,browserSocket,browser;
let failure;
const children=[];
function child(binary,args,options={}){const value=spawn(binary,args,{cwd:owned,detached:true,stdio:'ignore',...options});children.push(value);value.on('error',()=>{failure=new Error('Owned fixture child launch failed');});return value;}
function check(){if(failure)throw failure;}
async function terminate(value){if(!value||value.exitCode!==null)return;try{process.kill(-value.pid,'SIGTERM');}catch{}await Promise.race([new Promise(resolve=>value.once('close',resolve)),pause(2000)]);if(value.exitCode===null){try{process.kill(-value.pid,'SIGKILL');}catch{}await Promise.race([new Promise(resolve=>value.once('close',resolve)),pause(2000)]);}}
class CDP {
  constructor(socket) {
    this.socket = socket; this.id = 0; this.pending = new Map(); this.errors = [];
    socket.on('message', raw => {
      const value = JSON.parse(raw), pending = this.pending.get(value.id);
      if (pending) { this.pending.delete(value.id); clearTimeout(pending.timer);
        value.error ? pending.reject(new Error(value.error.message)) : pending.resolve(value.result); }
      if (value.method === 'Runtime.exceptionThrown') this.errors.push(value.params.exceptionDetails.text);
      startup.event(value.method);
    });
    socket.on('close', () => { for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('Chrome closed')); } this.pending.clear(); });
  }
  send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      const id = ++this.id, timer = setTimeout(() => { this.pending.delete(id); startup.timeout(method,this.pending.size); reject(new Error(`Chrome timeout: ${method}`)); }, 10_000);
      this.pending.set(id, {resolve,reject,timer}); this.socket.send(JSON.stringify({id,method,params,sessionId}));
    });
  }
  async evaluate(sessionId, expression) {
    const result = await this.send('Runtime.evaluate', {expression,returnByValue:true,awaitPromise:true,userGesture:true}, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  }
  async until(sessionId, expression, label) { return wait(label, () => this.evaluate(sessionId, expression)); }
}

const syntheticMedia = `
window.__fixturePeers=[];window.__fixtureCamera=[];window.__fixtureScreens=[];window.__fixtureAudio=[];
const Peer=window.RTCPeerConnection;window.RTCPeerConnection=class extends Peer{constructor(configuration){super({...configuration,iceTransportPolicy:"relay"});window.__fixturePeers.push(this);}};
const canvasTrack=color=>{const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;const context=canvas.getContext('2d');let counter=0;
const paint=()=>{context.fillStyle=color;context.fillRect(0,0,320,180);context.fillStyle='white';context.fillRect((counter++%80)*4,0,4,4);};paint();
const stream=canvas.captureStream(15),track=stream.getVideoTracks()[0];const timer=setInterval(()=>{if(track.readyState==='ended'){clearInterval(timer);return;}paint();},60);return stream;};
Object.defineProperty(navigator.mediaDevices,'enumerateDevices',{value:async()=>[]});
Object.defineProperty(navigator.mediaDevices,'getUserMedia',{value:async()=>{const camera=canvasTrack('rgb(220,20,15)');window.__fixtureCamera.push(camera);
const context=new AudioContext({sampleRate:48000});await context.resume();const destination=context.createMediaStreamDestination(),merge=context.createChannelMerger(2);
for(const [channel,frequency]of [[0,440],[1,880]]){const oscillator=context.createOscillator(),gain=context.createGain();oscillator.frequency.value=frequency;gain.gain.value=channel===0?.14:.07;oscillator.connect(gain).connect(merge,0,channel);oscillator.start();}
merge.connect(destination);window.__fixtureAudio.push({context,stream:destination.stream});destination.stream.getTracks()[0].addEventListener('ended',()=>context.close());return new MediaStream([...camera.getTracks(),...destination.stream.getTracks()]);}});
Object.defineProperty(navigator.mediaDevices,'getDisplayMedia',{value:async()=>{const stream=canvasTrack('rgb(15,20,220)');window.__fixtureScreens.push(stream);return stream;}});
`;


// Owned self-origin AudioWorklet asset, not a shipping page change or CSP
// bypass. Actual decoded PCM is measured on the rendering thread; the control
// page receives only bounded spectral/count receipts, never raw buffers.
// Mean Hann-window magnitudes do not require constant phase over adaptive
// WebRTC playout. Native source/RTP grid remains independently asserted.
const returnMeterModule = `
class ReturnMeter extends AudioWorkletProcessor {
  constructor(){super();this.revision=0;this.clear();this.port.onmessage=e=>{if(e.data?.type==='reset'&&Number.isSafeInteger(e.data.revision)){this.revision=e.data.revision;this.clear();}};}
  clear(){this.cueFrame=undefined;this.frames=0;this.windowFrames=0;this.windows=0;this.squared=[0,0];this.amplitudes=[Array(4).fill(0),Array(4).fill(0)];this.re=[Array(4).fill(0),Array(4).fill(0)];this.im=[Array(4).fill(0),Array(4).fill(0)];}
  process(inputs,outputs){
    const channels=inputs[0];if(!channels?.length)return true;
    const frequencies=[1000,1700,440,880],length=channels[0].length;
    for(let f=0;f<4;f++){
      const step=2*Math.PI*frequencies[f]/sampleRate,cs=Math.cos(step),sn=Math.sin(step),phase=step*(currentFrame%sampleRate);
      let c=Math.cos(phase),s=Math.sin(phase);
      for(let i=0;i<length;i++){for(let side=0;side<2;side++){const v=channels[Math.min(side,channels.length-1)][i],weight=.5-.5*Math.cos(2*Math.PI*(this.windowFrames+i)/2047);this.re[side][f]+=v*weight*c;this.im[side][f]+=v*weight*s;}
        const next=c*cs-s*sn;s=s*cs+c*sn;c=next;}
    }
    for(let side=0;side<2;side++)for(let i=0;i<length;i++){const v=channels[Math.min(side,channels.length-1)][i];this.squared[side]+=v*v;if(this.cueFrame===undefined&&Math.abs(v)>.025)this.cueFrame=currentFrame+i;}
    this.frames+=length;this.windowFrames+=length;
    if(this.windowFrames===2048){this.windowFrames=0;this.windows++;for(let side=0;side<2;side++)for(let f=0;f<4;f++){this.amplitudes[side][f]+=2*Math.hypot(this.re[side][f],this.im[side][f])/1023.5;this.re[side][f]=0;this.im[side][f]=0;}this.port.postMessage({cueContextSeconds:this.cueFrame===undefined?undefined:this.cueFrame/sampleRate,revision:this.revision,rate:sampleRate,frames:this.frames,n:this.frames,windows:this.windows,channels:this.squared.map((sum,side)=>({rms:Math.sqrt(sum/this.frames),amplitudes:this.amplitudes[side].map(value=>value/this.windows)}))});}
    return true;
  }
}
registerProcessor('stream-owned-return-meter',ReturnMeter);`;

try {
  const servicePort=await port(),inspectorPort=await port(),turnPort=await port();
  const origin=`http://127.0.0.1:${servicePort}`;
  const assets=path.join(owned,'assets');await fs.cp(path.join(workerRoot,'public'),assets,{recursive:true});
  await fs.writeFile(path.join(assets,'fixture-return-meter.js'),returnMeterModule,{mode:0o600});
  const operatorToken=randomBytes(32).toString('hex'),turnUsername=randomBytes(16).toString('hex'),turnCredential=randomBytes(32).toString('hex');
  const turnURL=`turn:127.0.0.1:${turnPort}?transport=udp`;
  const workerConfig={name:'native-session-relay-validation',main:path.join(workerRoot,'src/index.ts'),compatibility_date:'2026-10-02',compatibility_flags:['nodejs_compat'],durable_objects:{bindings:[{name:'ROOMS',class_name:'InterviewRoom'}]},migrations:[{tag:'v1',new_sqlite_classes:['InterviewRoom']}],assets:{directory:assets,binding:'ASSETS',run_worker_first:true},vars:{OPERATOR_TOKEN:operatorToken,ALLOWED_ORIGIN:origin,TURN_KEY_ID:''},observability:{enabled:false}};
  const config=path.join(owned,'wrangler.json'),relayConfig=path.join(owned,'turnserver.conf'),nativeConfig=path.join(owned,'native.json');
  await fs.writeFile(config,JSON.stringify(workerConfig),{mode:0o600});
  await fs.writeFile(nativeConfig,JSON.stringify({serviceURL:origin,operatorToken,turnURL,turnUsername,turnCredential,mediaDirectory:pathToFileURL(path.join(owned,"media")).href}),{mode:0o600});
  await fs.writeFile(relayConfig,[`listening-port=${turnPort}`,'listening-ip=127.0.0.1','relay-ip=127.0.0.1','min-port=49160','max-port=49175','realm=owned-fixture.invalid','lt-cred-mech',`user=${turnUsername}:${turnCredential}`,'fingerprint','allow-loopback-peers','allowed-peer-ip=127.0.0.1','denied-peer-ip=0.0.0.0-255.255.255.255','no-multicast-peers','no-tcp','no-tls','no-tcp-relay','no-stdout-log','log-file=/dev/null',`pidfile=${path.join(owned,'turn.pid')}`,`userdb=${path.join(owned,'turn.db')}`,'relay-threads=1','cpus=2','user-quota=8','total-quota=8','max-allocate-lifetime=120','max-bps=1048576','bps-capacity=8388608'].join('\n')+'\n',{mode:0o600});
  turn=child(turnserver,['-c',relayConfig]);
  worker=child(process.execPath,[path.join(workerRoot,'node_modules/wrangler/bin/wrangler.js'),'dev','--local','--config',config,'--ip','127.0.0.1','--port',String(servicePort),'--inspector-port',String(inspectorPort),'--persist-to',path.join(owned,'state'),'--log-level','none','--show-interactive-dev-session=false']);
  await wait('real local Worker readiness',async()=>{check();try{return(await fetch(`${origin}/guest.html`,{signal:AbortSignal.timeout(1000)})).status===200;}catch{return false;}},20_000);
  assert(turn.exitCode===null,'Owned Coturn must remain running');

  let pending='',nativeBytes=0,stderrBytes=0,state,invite,ack,stopped=false,closed=false,linesAfterStop=0;
  native=child(cli,[nativeConfig],{stdio:['pipe','pipe','pipe']});
  native.stdin.on('error',()=>{failure=new Error('Native command pipe closed');});
  native.stderr.on('data',chunk=>{stderrBytes+=chunk.length;if(stderrBytes>262144)failure=new Error('Native diagnostic budget exceeded');});
  native.on('close',(code,signal)=>{closed=true;if(!stopped||code!==0){console.error(`Owned native process exit: code=${code}, signal=${signal}; stderrBytes=${stderrBytes}`);failure??=new Error('Native process failed before terminal receipt');}});
  native.stdout.on('data',chunk=>{
    nativeBytes+=chunk.length;if(pending.length+chunk.length>65536){failure=new Error('Native receipt backlog exceeded');return;}
    pending+=chunk.toString('utf8');let newline;
    while((newline=pending.indexOf('\n'))!==-1){const line=pending.slice(0,newline);pending=pending.slice(newline+1);try{
      assert(line.length<=16384,'Native receipt bound');const value=JSON.parse(line);
      if(stopped){linesAfterStop++;throw new Error('Native emitted after stopped');}
      switch(value.type){
        case'private-invite':assert(!invite&&typeof value.url==='string'&&value.url.length<=2048,'Private invite IPC shape');invite=value.url;break;
        case'state':assert(typeof value.phase==='string'&&Array.isArray(value.members)&&value.members.length<=1,'Native state shape');state=value;break;
        case'ack':ack=value.command;break;
        case'stopped':stopped=true;break;
        case'error':throw new Error(`Native safe error: ${/^[a-zA-Z]{1,32}$/.test(value.reason)?value.reason:'unknown'}`);
        default:throw new Error('Unknown native receipt');
      }
    }catch(error){failure=new Error(String(error.message).slice(0,160));}}
  });
  function command(value){check();assert(native.stdin.writableLength<16384,'Native command backlog');native.stdin.write(JSON.stringify(value)+'\n');}
  command({type:'create'});await wait('native actual Worker create and host connect',()=>{check();return invite&&state?.phase==='connected';});
  const executable=await chromeFixtureExecutable(process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', owned);
  const profile=path.join(owned,'chrome');await fs.mkdir(profile,{mode:0o700});
  startup.phase('launch');
  chrome=child(executable,['--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--disable-background-networking','--disable-component-update','--disable-extensions','--autoplay-policy=no-user-gesture-required',...chromeFixtureCredentialArguments(),...(process.env.CHROME_NO_SANDBOX==='1'?['--no-sandbox']:[]),'about:blank'],{stdio:['ignore','ignore','pipe']});
  startup.observe(chrome);
  const debugging=await wait('isolated Chrome launch',async()=>{check();try{return(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).trim().split('\n');}catch{return undefined;}});
  startup.phase('debug-endpoint');
  browserSocket=new WebSocket(`ws://127.0.0.1:${debugging[0]}${debugging[1]}`,{handshakeTimeout:10_000});
  await new Promise((resolve,reject)=>{browserSocket.once('open',resolve);browserSocket.once('error',()=>reject(new Error('Chrome debug handshake failed')));});
  startup.phase('debug-connected');
  browser=new CDP(browserSocket);const version=await browser.send('Browser.getVersion');
  startup.version(version.product);startup.phase('browser-version');
  const target=await browser.send('Target.createTarget',{url:'about:blank'});startup.phase('target-created');
  const {sessionId:g}=await browser.send('Target.attachToTarget',{targetId:target.targetId,flatten:true});startup.phase('target-attached');
  await browser.send('Page.enable',{},g);await browser.send('Runtime.enable',{},g);
  startup.phase('page-runtime-enabled');
  const ownedTURNOverride=String.raw`const ownedRelay=${JSON.stringify({ttl:600,iceServers:[{urls:[turnURL],username:turnUsername,credential:turnCredential}]})};const originalFetch=window.fetch.bind(window);window.fetch=(input,init)=>{const url=new URL(typeof input==='string'?input:input.url,location.href);if(url.origin===location.origin&&/^\/v1\/rooms\/[0-9a-f-]+\/turn$/.test(url.pathname))return Promise.resolve(new Response(JSON.stringify(ownedRelay),{headers:{'Content-Type':'application/json'}}));return originalFetch(input,init);};`;
  await browser.send('Page.addScriptToEvaluateOnNewDocument',{source:syntheticMedia+ownedTURNOverride},g);
  startup.phase('navigate');
  await browser.send('Page.navigate',{url:invite},g);invite=undefined;
  startup.phase('navigation-accepted');
  await browser.until(g,"typeof document.getElementById('prepare').onclick==='function'",'actual guest page');
  startup.phase('guest-ready');
  assert(browser.errors.length===0&&await browser.evaluate(g,'Array.isArray(window.__fixtureCamera)'),'Generated capture and local TURN override must initialize without script errors');
  assert(await browser.evaluate(g,"location.hash===''")===true,'Guest strips capability fragment');
  await browser.evaluate(g,"document.getElementById('prepare').click()");await browser.until(g,"!document.getElementById('join').disabled",'generated devices prepared');
  await browser.evaluate(g,"document.getElementById('join').click()");
  await wait('native actual Worker waiting roster',()=>{check();return state?.members[0]?.membership==='waiting';});
  assert(await browser.evaluate(g,'window.__fixturePeers.length')===0,'No peer before actual service admission');

  const guest=state.members[0].id;command({type:'admit',id:guest});
  await wait('actual default Manager return ready',()=>{check();return state?.members[0]?.media==='ready'&&state?.members[0]?.returnAudio==='ready'&&state?.transport?.local==='relay'&&state?.audioAccepted>=5;},20000);
  await browser.until(g,"document.getElementById('return').srcObject?.getAudioTracks().length===1",'shipping guest return audio track');

  const returnAnalyzer=String.raw`(async()=>{
    window.__returnAnalysis?.processor.disconnect();window.__returnAnalysis?.source.disconnect();await window.__returnAnalysis?.context.close();
    const stream=document.getElementById('return').srcObject,track=stream.getAudioTracks()[0];
    const context=new AudioContext({sampleRate:48000});await context.resume();await context.audioWorklet.addModule('/fixture-return-meter.js');
    const source=context.createMediaStreamSource(new MediaStream([track])),processor=new AudioWorkletNode(context,'stream-owned-return-meter',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2]}),silent=context.createGain();silent.gain.value=0;
    const value={context,source,processor,track,revision:0,last:undefined};
    processor.port.onmessage=e=>{if(e.data.revision===value.revision)value.last=e.data;};
    source.connect(processor);processor.connect(silent).connect(context.destination);window.__returnAnalysis=value;
    window.__resetReturn=()=>{value.last=undefined;processor.port.postMessage({type:'reset',revision:++value.revision});};
    window.__returnSpectrum=()=>({...value.last,track:track.id,live:track.readyState});
    return{track:track.id,channels:track.getSettings().channelCount??0};
  })()`;
  await browser.evaluate(g,returnAnalyzer);
  async function spectrum(label,left,right){
    await browser.evaluate(g,'window.__resetReturn()');
    let observed;
    const result=await wait(label,async()=>{check();const r=await browser.evaluate(g,'window.__returnSpectrum()');observed=r;if(!r.n||r.n<24576)return false;const a=r.channels[0].amplitudes,b=r.channels[1].amplitudes;if(Math.abs(a[0]-left)>.035||Math.abs(b[1]-right)>.025||a[2]>.01||a[3]>.01||b[2]>.01||b[3]>.01)return false;return r;},6000).catch(error=>{console.error(`Observed actual Chrome ${label}: ${JSON.stringify(observed)}`);throw error;});
    assert(result.rate===48000&&result.live==='live'&&result.channels.length===2);if(left===0&&right===0)assert(result.channels.every(c=>c.rms<.002),'Muted return must carry actual near-zero decoded PCM');console.log(`Actual Chrome decoded return ${label}: ${JSON.stringify(result)}`);return result;
  }
  const first=await spectrum('backstage-local-only',.4,.2);
  const videoPixels=`(()=>{const v=document.getElementById('return');if(!v.srcObject?.getVideoTracks().length||v.readyState<2)return null;const c=document.createElement('canvas');c.width=v.videoWidth;c.height=v.videoHeight;c.getContext('2d').drawImage(v,0,0);const pixel=[...c.getContext('2d').getImageData(c.width/2,c.height/2,1,1).data].slice(0,3);return{width:c.width,height:c.height,pixel,track:v.srcObject.getVideoTracks()[0].id};})()`;
  assert(await browser.evaluate(g,"document.getElementById('return').srcObject.getVideoTracks().length===0"),'Program video is opt-in, with no visible remote video before enable');
  command({type:'video-on'});
  await wait('actual fixed Program return decoded green pixels',async()=>{check();const r=await browser.evaluate(g,videoPixels);return r?.pixel[1]>150&&r.pixel[0]<60&&r.pixel[2]<110&&r.width<=320&&r.height<=180;},20000);
  const originalVideo=await browser.evaluate(g,videoPixels);console.log(`Actual native Program return green: ${JSON.stringify(originalVideo)}`);
  const decodedVideoStats=`(async()=>{const stats=await window.__fixturePeers.at(-1).getStats();for(const r of stats.values())if(r.type==='inbound-rtp'&&r.kind==='video')return{frames:r.framesDecoded,width:r.frameWidth,height:r.frameHeight,fps:r.framesPerSecond,codec:stats.get(r.codecId)?.mimeType};return null;})()`;
  await wait('real Chrome H264 return codec and frame count',async()=>{const r=await browser.evaluate(g,decodedVideoStats);return r?.codec==='video/H264'&&r.frames>=5&&r.width<=320&&r.height<=180;});
  ack=undefined;command({type:'video-budget-held'});await wait('actual aggregate reservation includes active return encoder',()=>{check();return ack==='video-budget-held';});
  command({type:'video-black'});
  await wait('actual taken black Program replaces prior return pixels',async()=>{check();const r=await browser.evaluate(g,videoPixels);return r&&r.pixel.every(v=>v<8);});
  command({type:'video-off'});
  await browser.until(g,"document.getElementById('return').srcObject?.getVideoTracks().length===0",'explicit stop clears visible return video');
  ack=undefined;command({type:'video-budget-free'});await wait('actual VT teardown releases aggregate reservation',()=>{check();return ack==='video-budget-free';});
  command({type:'video-purple'});await pause(350);
  assert(await browser.evaluate(g,"document.getElementById('return').srcObject.getVideoTracks().length===0"),'New Program changes cannot re-open stopped video return');
  command({type:'video-on'});
  await wait('fresh opt-in decodes current purple Program',async()=>{check();const r=await browser.evaluate(g,videoPixels);return r?.pixel[0]>100&&r.pixel[1]<80&&r.pixel[2]>140;},20000);
  console.log(`PASS actual native fixed Program H264 return: current pixels, <=320x180 bounds, deliberate start/stop/restart and hidden stopped video; ${JSON.stringify(await browser.evaluate(g,videoPixels))}`);
  if(!process.argv.includes('--video-fault-only')){
  await pause(3500); // Require late cues after multiple shared-clock sender reports.
  command({type:'video-black'});ack=undefined;command({type:'mute'});await wait('mute before return AV recording',()=>{check();return ack==='mute';});
  await pause(400); // Drain the already accepted public return tail before measuring silence.
  await spectrum('video-av-silent-baseline',0,0);
  await wait('black before actual return AV recording',async()=>{const r=await browser.evaluate(g,videoPixels);return r&&r.pixel.every(v=>v<8);});
  await browser.evaluate(g,`(()=>{const stream=document.getElementById('return').captureStream();window.__returnParts=[];window.__returnRecorder=new MediaRecorder(stream,{mimeType:'video/webm;codecs=vp8,opus',videoBitsPerSecond:400000,audioBitsPerSecond:128000});window.__returnRecorder.ondataavailable=e=>{if(e.data.size)window.__returnParts.push(e.data);};window.__returnRecorder.start();})()`);
  await browser.evaluate(g,`(()=>{window.__resetReturn();window.__videoFlashPerf=undefined;const v=document.getElementById('return'),c=document.createElement('canvas');c.width=1;c.height=1;const context=c.getContext('2d');const observe=(now,meta)=>{context.drawImage(v,0,0,1,1);const p=context.getImageData(0,0,1,1).data;if(p[0]>200&&p[1]>200&&p[2]>200)window.__videoFlashPerf??=meta.expectedDisplayTime;else v.requestVideoFrameCallback(observe);};v.requestVideoFrameCallback(observe);})()`);
  await pause(600);command({type:'video-av'});await pause(1500);
  const actualPlayout=await browser.evaluate(g,`(()=>{const a=window.__returnAnalysis,stamp=a.context.getOutputTimestamp(),cue=a.last?.cueContextSeconds,audio=cue===undefined?undefined:stamp.performanceTime+(cue-stamp.contextTime)*1000;return{videoMilliseconds:window.__videoFlashPerf,audioMilliseconds:audio,deltaMilliseconds:window.__videoFlashPerf-audio};})()`);
  console.log(`Actual return element playout cue metadata: ${JSON.stringify(actualPlayout)}`);
  const transportTiming=await browser.evaluate(g,String.raw`(async()=>{const pc=window.__fixturePeers.at(-1),stats=await pc.getStats(),r=[];for(const s of stats.values())if(s.type==='inbound-rtp')r.push({kind:s.kind,jitterBufferDelay:s.jitterBufferDelay,jitterBufferEmittedCount:s.jitterBufferEmittedCount,estimatedPlayoutTimestamp:s.estimatedPlayoutTimestamp,lastPacketReceivedTimestamp:s.lastPacketReceivedTimestamp,codec:stats.get(s.codecId)?.mimeType});return{stats:r,mediaIdentity:pc.remoteDescription.sdp.split('\r\n').filter(l=>/^a=ssrc:\d+ (?:cname|msid):stream-return(?: |$)/.test(l))};})()`);
  console.log(`Actual return RTP timing and public stream identity: ${JSON.stringify(transportTiming)}`);
  const encodedRecording=await browser.evaluate(g,`new Promise(resolve=>{window.__returnRecorder.onstop=async()=>{const bytes=new Uint8Array(await new Blob(window.__returnParts).arrayBuffer());let value='';for(let i=0;i<bytes.length;i+=8192)value+=String.fromCharCode(...bytes.subarray(i,i+8192));resolve(btoa(value));};window.__returnRecorder.stop();})`);
  assert(typeof encodedRecording==='string'&&encodedRecording.length<1048576,'Bounded owned return AV recording');
  const avPath=path.join(owned,'decoded-return-av.webm');await fs.writeFile(avPath,Buffer.from(encodedRecording,'base64'),{mode:0o600});
  const retained=path.resolve(workerRoot,'../../apple/build/native-interview-return-video-validation',`decoded-return-${Date.now()}.webm`);
  await fs.mkdir(path.dirname(retained),{recursive:true});await fs.copyFile(avPath,retained);
  console.log(`Owned decoded return AV artifact: ${retained}`);
  console.log(`Original native source AV cues: ${JSON.stringify({native:state.av??{},authored:state.authoredAV??{}})}`);
  assert(Number.isFinite(state.av?.delta)&&Math.abs(state.av.delta)<.05,'Owned native Program cue must be aligned within50ms before testing transport synchronization');
  console.log(`PASS actual Chrome decoded Program video/Opus AV cue: ${JSON.stringify(analyzeReturnAV(avPath))}`);
  }else{console.log('Scope: focused partial-AU invocation; decoded AV cue qualification is separate.');}
  command({type:'video-noise'});await pause(500);
  const beforeFault=await browser.evaluate(g,decodedVideoStats);command({type:'video-fault'});
  await wait('actual SDK fragmented AU prefix then controlled failed send',()=>{check();return state.videoFault?.failed&&state.videoFault.fragmented&&state.videoFault.forwarded===4;});
  await wait('next successful native AU is a forced IDR',()=>{check();return state.videoFault.recoveryChecked&&state.videoFault.recoveredIDR;});
  command({type:'video-green'});
  await wait('actual Chrome H264 pixels recover after partial AU send failure',async()=>{check();const p=await browser.evaluate(g,videoPixels),r=await browser.evaluate(g,decodedVideoStats);return p?.pixel[1]>150&&p.pixel[0]<60&&p.pixel[2]<110&&r.frames>beforeFault.frames+2;});
  console.log(`PASS actual SDK fragmented partial AU failure and next-IDR Chrome decode recovery: ${JSON.stringify(state.videoFault)}`);
  command({type:'video-purple'});
  await wait('current purple Program restored after recovery',async()=>{const r=await browser.evaluate(g,videoPixels);return r?.pixel[0]>100&&r.pixel[1]<80&&r.pixel[2]>140;});
  const pair=await browser.evaluate(g,`(async()=>{const pc=window.__fixturePeers.at(-1),stats=await pc.getStats();let result={};for(const s of stats.values()){if(s.type==='inbound-rtp'&&s.kind==='audio'){result={...result,packets:s.packetsReceived,samples:s.totalSamplesReceived,codec:stats.get(s.codecId)?.mimeType,channels:stats.get(s.codecId)?.channels};}if(s.type==='transport'&&s.selectedCandidatePairId){const pair=stats.get(s.selectedCandidatePairId);result={...result,local:stats.get(pair.localCandidateId)?.candidateType,remote:stats.get(pair.remoteCandidateId)?.candidateType};}}return result;})()`);
  assert(pair.local==='relay'&&pair.packets>10&&pair.samples>24000&&pair.codec==='audio/opus'&&state.transport.local==='relay'&&state.transport.udp);
  console.log(`Actual decoded Opus and both-local relay metadata: ${JSON.stringify(pair)}`);
  const messageDigest=text=>createHash('sha256').update(text).digest('hex');
  const privateHostText='Owned shipping Manager private message ✓';
  await browser.until(g,"!document.getElementById('message').disabled",'shipping native capability enables private composer');
  assert(!state.programAllowed,'Private message proof begins backstage');
  command({type:'message',id:guest,text:privateHostText});
  await wait('shipping Dispatcher/Manager/default SDK actual guest receipt',()=>{check();return state.privateMessages?.some(value=>!value.fromGuest&&value.digest===messageDigest(privateHostText)&&value.delivery==='received');});
  const privateGuestText='Owned shipping guest private message ✓';
  await browser.evaluate(g,`document.getElementById('message').value=${JSON.stringify(privateGuestText)};document.getElementById('message').dispatchEvent(new Event('input'));document.getElementById('sendmessage').click()`);
  await wait('actual guest SDK text enters shipping Manager',()=>{check();return state.privateMessages?.some(value=>value.fromGuest&&value.digest===messageDigest(privateGuestText));});
  await browser.until(g,"document.getElementById('messages').textContent.includes('Host received')",'actual shipping host acknowledgment');
  assert(!state.programAllowed,'Private conversation cannot open Program admission');
  await spectrum('backstage-private-messages-no-audio-route-change',.4,.2);
  command({type:'onair',id:guest});await wait('actual Program guest admission',()=>{check();return state.programAllowed&&state.members[0]?.returnAudio==='ready'&&state.program?.own440and880[0]>.07&&state.program?.own440and880[1]>.025;});
  console.log(`Actual own signal positive in shipping Program before return exclusion: ${JSON.stringify(state.program)}`);await spectrum('onair-own440-880-excluded',.4,.2);
  ack=undefined;command({type:'mute'});await wait('actual local mixer mute acknowledged',()=>{check();return ack==='mute';});await pause(400);await spectrum('local-muted',0,0);
  ack=undefined;command({type:'restore'});await wait('actual local mixer nonunity restore acknowledged',()=>{check();return ack==='restore';});await pause(300);await spectrum('local-nonunity-restore',.16,.08);
  const oldGeneration=state.lease.generation;
  await browser.evaluate(g,'window.__priorReturnTrack=window.__returnAnalysis.track');command({type:'rejoin'});
  await browser.until(g,"document.getElementById('return').srcObject===null",'shipping guest reset clears return after host disconnect');
  assert(await browser.evaluate(g,"window.__returnAnalysis.track.readyState==='ended'")===true,'Actual previous remote return track retires');
  await wait('actual host reconnected awaiting admission',()=>{check();return state.phase==='connected'&&state.members[0]?.membership==='waiting';});
  command({type:'admit',id:guest});await wait('fresh full lease actual return ready',()=>{check();return state.lease?.generation>oldGeneration&&state.members[0]?.returnAudio==='ready'&&state.transport?.local==='relay';},20000);
  await browser.until(g,"document.getElementById('return').srcObject?.getAudioTracks().length===1",'new shipping return stream');
  await browser.evaluate(g,returnAnalyzer);await spectrum('rejoined-new-fulllease',.16,.08);
  assert(await browser.evaluate(g,"document.getElementById('return').srcObject.getVideoTracks().length===0"),'A new full lease cannot inherit Program video opt-in');
  command({type:'video-on'});
  await wait('fresh lease Program video decoded after explicit enable',async()=>{check();const r=await browser.evaluate(g,videoPixels);return r?.pixel[0]>100&&r.pixel[1]<80&&r.pixel[2]>140;},20000);
  console.log('PASS actual native Program return fresh-lease opt-in and decoded current purple pixels after rejoin');
  assert(await browser.evaluate(g,'window.__returnAnalysis.track!==window.__priorReturnTrack')===true,'A fresh actual remote track object must replace the retired track; role ID may remain stable');
  await wait('shipping Manager private history cleared on actual rejoin',()=>{check();return state.privateMessages?.length===0;});
  assert(await browser.evaluate(g,"document.getElementById('messages').children.length===0 && document.getElementById('message').value===''")===true,'Guest private history/draft clears after actual fulllease replacement');
  ack=undefined;command({type:'stale-message'});await wait('retained real Manager private command rejected',()=>{check();return ack==='stale-message-rejected';});
  assert(state.privateMessages.length===0,'Stale command cannot populate replacement conversation');
  command({type:'message',id:guest,text:'Owned new explicit private message'});
  await wait('new fulllease accepts deliberate private message',()=>{check();return state.privateMessages?.some(value=>value.delivery==='received');});
  console.log('PASS actual shipping Dispatcher/Manager/current fulllease/default native SDK + local relay Chrome private conversation: both directions/receipts, backstage route independence, actual rejoin wipe, retained command rejection and deliberate fresh send');
  command({type:'remove',id:guest});await browser.until(g,"document.getElementById('return').srcObject===null",'removed guest retires remote return');
  await wait('native removal retires fulllease',()=>{check();return !state.lease&&!state.members.some(member=>member.id===guest);});
  command({type:'end'});await wait('actual room ended',()=>{check();return state.phase==='ended';});
  command({type:'stop'});await wait('native permanent cleanup receipt',()=>{check();return stopped&&closed;},10000);assert(linesAfterStop===0);
  assert(browser.errors.length===0,'Actual shipping guest page no runtime errors');
  console.log(`PASS ${version.product}: actual shipping NativeInterviewManager/default receiver/controller-issued sink→preclamp fulllease return→public native stereo Opus→SDK RTP/RTCP→owned TURN→shipping guest audio track/Chrome decoded48k PCM; own440/880 excluded, local1000/1700 preserved, mute/nonunity restore, new-generation rejoin and remove fence`);
  console.log('Scope: owned local Worker/Coturn/synthetic captures only. Fixed Program video and public stereo audio only; clean/secondary video, adaptive transport feedback, addressed talkback, physical/browser AEC, mobile/restricted-network/deployed broker remain unqualified.');
} finally {
  browserSocket?.close();for(const value of children.reverse())await terminate(value);
  await fs.rm(owned,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
