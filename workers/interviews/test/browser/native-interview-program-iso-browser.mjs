// Actual local Worker control + owned Coturn relay + shipping native session,
// receiver adapter and leased sink. Generated capture inputs only, no devices.
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {WebSocket} from 'ws';
import {chromeFixtureExecutable, chromeFixtureCredentialArguments, ChromeFixtureDiagnostics} from './chrome-fixture.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const startup=new ChromeFixtureDiagnostics();
async function wait(label,predicate,timeout=15_000){const end=Date.now()+timeout;while(Date.now()<end){const value=await predicate();if(value)return value;await pause(50);}throw new Error(`Bounded fixture timeout: ${label}`);}
async function port(){const server=net.createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const value=server.address().port;await new Promise(resolve=>server.close(resolve));return value;}
const workerRoot=fileURLToPath(new URL('../../',import.meta.url));
const cli=process.env.NATIVE_INTERVIEW_PROGRAM_ISO_CLI, turnserver=process.env.STREAM_INTERVIEW_TURN_SERVER;
assert(cli&&path.isAbsolute(cli)&&turnserver&&path.isAbsolute(turnserver),'Set absolute owned native CLI and pinned Coturn executable paths');
await fs.access(cli,fs.constants.X_OK);await fs.access(turnserver,fs.constants.X_OK);
const owned=await fs.mkdtemp(path.join(os.tmpdir(),'stream-native-session-relay-'));await fs.chmod(owned,0o700);
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
const paint=()=>{const audio=window.__fixtureAudio.at(-1),at=window.__fixtureCueAt;const flash=color==='rgb(220,20,15)'&&audio&&at&&audio.context.currentTime>=at&&audio.context.currentTime<at+.35;context.fillStyle=flash?'white':color;context.fillRect(0,0,320,180);context.fillStyle='white';context.fillRect((counter++%80)*4,0,4,4);};paint();
const stream=canvas.captureStream(30),track=stream.getVideoTracks()[0];const timer=setInterval(()=>{if(track.readyState==='ended'){clearInterval(timer);return;}paint();},16);return stream;};
Object.defineProperty(navigator.mediaDevices,'enumerateDevices',{value:async()=>[]});
Object.defineProperty(navigator.mediaDevices,'getUserMedia',{value:async()=>{const camera=canvasTrack('rgb(220,20,15)');window.__fixtureCamera.push(camera);
const context=new AudioContext({sampleRate:48000});await context.resume();const destination=context.createMediaStreamDestination(),merge=context.createChannelMerger(2),gains=[];
for(const [channel,frequency]of [[0,440],[1,880]]){const oscillator=context.createOscillator(),gain=context.createGain();oscillator.frequency.value=frequency;gain.gain.value=channel===0?.14:.07;oscillator.connect(gain).connect(merge,0,channel);oscillator.start();gains.push(gain);}
merge.connect(destination);window.__fixtureAudio.push({context,stream:destination.stream,gains});destination.stream.getTracks()[0].addEventListener('ended',()=>context.close());return new MediaStream([...camera.getTracks(),...destination.stream.getTracks()]);}});
window.__fixtureMute=()=>{for(const gain of window.__fixtureAudio.at(-1).gains){gain.gain.cancelScheduledValues(0);gain.gain.setValueAtTime(0,window.__fixtureAudio.at(-1).context.currentTime);}};
window.__fixtureAudible=()=>{for(const [index,gain]of window.__fixtureAudio.at(-1).gains.entries()){gain.gain.cancelScheduledValues(0);gain.gain.setValueAtTime(index===0?.14:.07,window.__fixtureAudio.at(-1).context.currentTime);}};
window.__fixtureCue=()=>{const audio=window.__fixtureAudio.at(-1),at=audio.context.currentTime+.5;window.__fixtureCueAt=at;for(const [index,gain]of audio.gains.entries()){gain.gain.setValueAtTime(index===0?.14:.07,at);gain.gain.setValueAtTime(0,at+1);}};
Object.defineProperty(navigator.mediaDevices,'getDisplayMedia',{value:async()=>{const stream=canvasTrack('rgb(15,20,220)');window.__fixtureScreens.push(stream);return stream;}});
`;

try {
  const servicePort=await port(),inspectorPort=await port(),turnPort=await port();
  const origin=`http://127.0.0.1:${servicePort}`;
  const operatorToken=randomBytes(32).toString('hex'),turnUsername=randomBytes(16).toString('hex'),turnCredential=randomBytes(32).toString('hex');
  const turnURL=`turn:127.0.0.1:${turnPort}?transport=udp`;
  const workerConfig={name:'native-session-relay-validation',main:path.join(workerRoot,'src/index.ts'),compatibility_date:'2026-10-02',compatibility_flags:['nodejs_compat'],durable_objects:{bindings:[{name:'ROOMS',class_name:'InterviewRoom'}]},migrations:[{tag:'v1',new_sqlite_classes:['InterviewRoom']}],assets:{directory:path.join(workerRoot,'public'),binding:'ASSETS',run_worker_first:true},vars:{OPERATOR_TOKEN:operatorToken,ALLOWED_ORIGIN:origin,TURN_KEY_ID:''},observability:{enabled:false}};
  const config=path.join(owned,'wrangler.json'),relayConfig=path.join(owned,'turnserver.conf'),nativeConfig=path.join(owned,'native.json');
  const mediaDirectory=process.env.STREAM_INTERVIEW_PROGRAM_ARTIFACTS??path.join(owned,'media');
  assert(path.isAbsolute(mediaDirectory),'Use an absolute owned media artifact directory');
  await fs.mkdir(mediaDirectory,{recursive:true,mode:0o700});
  await fs.writeFile(config,JSON.stringify(workerConfig),{mode:0o600});
  await fs.writeFile(nativeConfig,JSON.stringify({serviceURL:origin,operatorToken,turnURL,turnUsername,turnCredential,mediaDirectory:pathToFileURL(mediaDirectory).href}),{mode:0o600});
  await fs.writeFile(relayConfig,[`listening-port=${turnPort}`,'listening-ip=127.0.0.1','relay-ip=127.0.0.1','min-port=49160','max-port=49175','realm=owned-fixture.invalid','lt-cred-mech',`user=${turnUsername}:${turnCredential}`,'fingerprint','allow-loopback-peers','allowed-peer-ip=127.0.0.1','denied-peer-ip=0.0.0.0-255.255.255.255','no-multicast-peers','no-tcp','no-tls','no-tcp-relay','no-stdout-log','log-file=/dev/null',`pidfile=${path.join(owned,'turn.pid')}`,`userdb=${path.join(owned,'turn.db')}`,'relay-threads=1','cpus=2','user-quota=8','total-quota=8','max-allocate-lifetime=120','max-bps=1048576','bps-capacity=8388608'].join('\n')+'\n',{mode:0o600});
  turn=child(turnserver,['-c',relayConfig]);
  worker=child(process.execPath,[path.join(workerRoot,'node_modules/wrangler/bin/wrangler.js'),'dev','--local','--config',config,'--ip','127.0.0.1','--port',String(servicePort),'--inspector-port',String(inspectorPort),'--persist-to',path.join(owned,'state'),'--log-level','none','--show-interactive-dev-session=false']);
  await wait('real local Worker readiness',async()=>{check();try{return(await fetch(`${origin}/guest.html`,{signal:AbortSignal.timeout(1000)})).status===200;}catch{return false;}},20_000);
  assert(turn.exitCode===null,'Owned Coturn must remain running');
  let pending='',stderrBytes=0,state,invite,proofs=[],quiet=0,oldISO=false,stopped=false,closed=false,linesAfterStop=0;
  native=child(cli,[nativeConfig],{stdio:['pipe','pipe','pipe']});
  native.stdin.on('error',()=>{failure=new Error('Native command pipe closed');});
  let nativeDiagnostic='';native.stderr.on('data',chunk=>{stderrBytes+=chunk.length;if(stderrBytes>262_144)failure??=new Error('Native diagnostic budget exceeded');nativeDiagnostic=(nativeDiagnostic+chunk.toString('utf8')).slice(-8192);const match=nativeDiagnostic.match(/(native_interview_program_iso_(?:cli|analysis)\.swift):(\d+): (Fatal error|Precondition failed|Assertion failed)(?:: ([A-Za-z0-9 .\/\-]{1,180}))?/);if(match)console.log(`Native fixture assertion: ${match[1]}:${match[2]} ${match[3]} ${match[4]??''}`);});
  native.on('close',(code,signal)=>{closed=true;if(!stopped||code!==0){console.log(`Native fixture exit code=${Number.isInteger(code)?code:'none'} signal=${/^[A-Z]{3,12}$/.test(signal??'')?signal:'none'}`);failure??=new Error('Native process failed before terminal receipt');}});
  native.stdout.on('data',chunk=>{
    if(pending.length+chunk.length>65_536){failure=new Error('Native receipt backlog exceeded');return;}
    pending+=chunk.toString('utf8');let newline;
    while((newline=pending.indexOf('\n'))!==-1){const line=pending.slice(0,newline);pending=pending.slice(newline+1);try{
      assert(line.length<=16_384,'Native receipt bound');const value=JSON.parse(line);
      if(stopped){linesAfterStop++;throw new Error('Native emitted after stopped');}
      switch(value.type){
        case'private-invite':assert(!invite&&typeof value.url==='string'&&value.url.length<=2048,'Private invite IPC shape');invite=value.url;break;
        case'state':assert(typeof value.phase==='string'&&Array.isArray(value.members)&&value.members.length<=1,'Native state shape');state=value;break;
        case'proof':assert(Number.isSafeInteger(value.segment)&&value.decodedPCMFrames>96000&&value.matchingFloat32Values===value.decodedPCMFrames*2&&value.endsBlackSilent,'Strict actual encoded proof');proofs.push(value);break;
        case'quiet':assert(value.passed===true);quiet++;break;
        case'old-iso':assert(value.rejected===true);oldISO=true;break;
        case'clock-trace':{
          assert(['decodedFlash','decodedTone','programFlash','programTone'].every(key=>Number.isFinite(value[key])&&value[key]>0));
          const h=value.history;assert(h?.misses===0,'Actual ISO flash queries must retain their original due camera frames');
          console.log(`Actual accepted receipt clock trace: ${JSON.stringify({sourceAV:value.decodedFlash-value.decodedTone,programAV:value.programFlash-value.programTone,videoPlayout:value.programFlash-value.decodedFlash,audioPlayout:value.programTone-value.decodedTone,isoHistoryMisses:h?.misses,oldestAhead:h?.oldest-h?.query,newestAhead:h?.newest-h?.query,isoQueryBehindHost:h?.host-h?.query})}`);break;
        }
        case'stopped':stopped=true;break;
        case'error':throw new Error(`Native safe error: ${/^[a-zA-Z]{1,32}$/.test(value.reason)?value.reason:'unknown'}`);
        default:throw new Error('Unknown native receipt');
      }
    }catch(error){failure??=new Error(error instanceof SyntaxError?'Native receipt JSON malformed':String(error.message).slice(0,160));}}
  });
  function command(value){check();assert(native.stdin.writableLength<16_384,'Native command backlog');native.stdin.write(JSON.stringify(value)+'\n');}
  command({type:'create'});await wait('native actual Worker create and host connect',()=>{check();return invite&&state?.phase==='connected';});
  const executable=await chromeFixtureExecutable(process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', owned);
  const profile=path.join(owned,'chrome');await fs.mkdir(profile,{mode:0o700});
  startup.phase('launch');
  chrome=child(executable,['--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--disable-background-networking','--disable-component-update','--disable-extensions','--autoplay-policy=no-user-gesture-required',...chromeFixtureCredentialArguments(),'about:blank'],{stdio:['ignore','ignore','pipe']});
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
  const ready=()=>state?.members[0]?.media==='ready'&&state?.lease&&state.transport?.local==='relay'&&state.transport.udp;
  await wait('default production Manager receiver and real registered media',()=>{check();return ready()&&state.acceptedVideo>=4&&state.audioAccepted>=5;},20_000);
  assert(state.members[0].membership==='backstage'&&!state.programAllowed,'Real admission begins backstage with no Program route');
  const pair=await browser.evaluate(g,`(async()=>{const pc=window.__fixturePeers.at(-1),stats=await pc.getStats();for(const transport of stats.values()){if(transport.type==='transport'&&transport.selectedCandidatePairId){const pair=stats.get(transport.selectedCandidatePairId),local=stats.get(pair.localCandidateId),remote=stats.get(pair.remoteCandidateId);return{local:local.candidateType,remote:remote.candidateType,protocol:local.protocol,sent:pair.bytesSent,received:pair.bytesReceived};}}return null;})()`);
  assert(pair?.local==='relay'&&pair.sent>0&&pair.received>0&&state.transport.local==='relay','Both actual local candidates must be relay with received media');
  console.log(`Actual default Manager relay pair metadata: Chrome ${JSON.stringify(pair)}; native ${JSON.stringify(state.transport)}`);
  const original={...state.lease};
  function phase(label){console.log(`Native recording phase: ${JSON.stringify({phase:label,service:state?.phase,membership:state?.members[0]?.membership,revision:state?.members[0]?.revision,media:state?.members[0]?.media,programAllowed:state?.programAllowed,generation:state?.lease?.generation,video:state?.acceptedVideo,audio:state?.audioAccepted,audioPTS:state?.audioPTS,audioRejected:state?.audioRejected,live:state?.live,receiver:state?.receiver})}`);}
  async function audioTransport(){return browser.evaluate(g,`(async()=>{const pc=window.__fixturePeers.at(-1),stats=await pc.getStats();const packets=[];for(const value of stats.values())if(value.type==='outbound-rtp'&&value.kind==='audio')packets.push({packetsSent:value.packetsSent,bytesSent:value.bytesSent,totalSamplesSent:value.totalSamplesSent});const audio=window.__fixtureAudio.at(-1);return{connection:pc.connectionState,audioState:audio.context.state,audioTime:audio.context.currentTime,gains:audio.gains.map(g=>g.gain.value),packets};})()`);}
  await wait('actual Chrome sparse Opus sender-report cadence exceeds3s',()=>{check();return state.receiver?.roles.find(value=>value.role===2)?.srAge>3.1;});
  const sparseBefore={audio:state.audioAccepted,unsynchronized:state.receiver.unsynchronized};
  await pause(350);check();phase('actual-sparse-opus-report');
  assert(state.audioAccepted>=sparseBefore.audio+10&&state.receiver.unsynchronized===sparseBefore.unsynchronized,
    'Real ordinary Chrome Opus must keep decoding past3s report age without discarding synchronized RTP');
  async function segment(number){
    command({type:'begin'});await browser.evaluate(g,'window.__fixtureAudible()');
    await wait('actual Program and controller-resolved ISO taps',()=>{check();return state.live?.pictures>=6&&state.live.programPackets>=20&&state.live.isoPackets>=20;});
    await pause(350);let quietBefore=quiet;command({type:'quiet'});await wait('backstage real pixels/PCM withheld from both outputs',()=>quiet>quietBefore);
    assert(!state.programAllowed,'Program route cannot precede an explicit OnAir intent and actual receipt');
    await browser.evaluate(g,'window.__fixtureMute()');await pause(350);
    const revision=state.members[0].revision;command({type:'onair',id:guest});
    await wait('actual stage ACK before default Controller Program routing',()=>{check();return state.programAllowed&&state.members[0].membership==='onair'&&state.members[0].revision>revision;});
    await wait('actual default shipping Composer renders native camera',()=>{check();return state.live?.rgb[0]>180&&state.live.rgb[1]<80&&state.live.rgb[2]<80;});
    phase(`segment${number}-onair`);
    if(number===2){command({type:'old-iso'});await wait('captured first ISO rejects real new-generation pixels',()=>oldISO);}
    await browser.evaluate(g,'window.__fixtureCue()');
    await wait('actual Chrome flash/tone survive native compositor and mixer',()=>{check();return state.live?.whiteFrames>=1&&state.live.audiblePackets>=30;});
    if(number===1){
      assert(state.members[0].approved===false&&await browser.evaluate(g,"document.getElementById('share').disabled"),'Screen starts denied');
      command({type:'approval',id:guest,approved:true});await browser.until(g,"!document.getElementById('share').disabled",'real native approval channel');
      await browser.evaluate(g,"document.getElementById('share').click()");
      await wait('real separate native screen MID painted by shipping Composer',()=>{check();return state.members[0].sharing&&state.live.screenRGB[2]>150&&state.live.screenRGB[0]<80;},20_000);
      const camera=state.acceptedVideo,audio=state.audioAccepted;
      await browser.evaluate(g,"document.getElementById('stopshare').click()");command({type:'approval',id:guest,approved:false});
      await wait('actual screen revocation reaches live Composer',()=>{check();return state.members[0].approved===false&&!state.members[0].sharing&&state.live.screenRGB[0]>150&&state.live.screenRGB[2]<80;});
      await pause(350);check();assert(state.acceptedVideo>camera&&state.audioAccepted>audio,'Camera/audio remain healthy after independent screen stop');
    } else {assert(state.members[0].approved===false&&!state.members[0].sharing,'Fresh full lease cannot inherit screen grant');await pause(750);}
    command({type:'backstage',id:guest});await wait('actual synchronous Program route revoked',()=>{check();return !state.programAllowed;});
    phase(`segment${number}-backstage`);const transportBefore=await audioTransport();
    const backstageAudio=state.audioAccepted;await browser.evaluate(g,'window.__fixtureAudible()');
    await pause(350);phase(`segment${number}-backstage-audible`);console.log(`Backstage generated audio transport: ${JSON.stringify({before:transportBefore,after:await audioTransport()})}`);
    assert(state.audioAccepted>backstageAudio,'Actual decoder must keep receiving generated audible RTP after Backstage');quietBefore=quiet;command({type:'quiet'});await wait('actual live backstage tail black/silent in Program and pre-fader ISO',()=>quiet>quietBefore);
    command({type:'finish'});await wait('actual AAC/H264 files decoded with strict shared-clock proof',()=>{check();return proofs.some(value=>value.segment===number);},20_000);
    const proof=proofs.find(value=>value.segment===number);
    assert(Math.abs(proof.liveAVDelta)<.05&&Math.abs(proof.programAVDelta)<.05&&Math.abs(proof.isoAVDelta)<.05&&Math.abs(proof.programEndDelta)<.04&&Math.abs(proof.isoEndDelta)<.04);
    assert(proof.rationalCueValue/proof.rationalCueScale<=1/48000&&proof.preWriterWindows>=30);
    console.log(`PASS actual Manager/default receiver/Controller Program+ISO segment${number}: ${JSON.stringify(proof)}`);
  }
  await segment(1);
  command({type:'rejoin'});await wait('actual Manager explicitly rejoins real service',()=>{check();return state.phase==='connected'&&state.members[0]?.membership==='waiting'&&!state.programAllowed;});
  const before={video:state.acceptedVideo,audio:state.audioAccepted};command({type:'admit',id:guest});
  await wait('fresh actual native default factory lease and decoded media',()=>{check();return ready()&&state.lease.generation>original.generation&&state.acceptedVideo>=before.video+3&&state.audioAccepted>=before.audio+3;},20_000);
  assert(state.lease.slot===original.slot&&state.lease.negotiation!==original.negotiation,'Actual rejoin preserves stable source slot and replaces full authority');
  assert(state.members[0].membership==='backstage'&&!state.programAllowed&&state.members[0].approved===false,'Rejoin cannot replay Program or screen intent');
  await segment(2);
  command({type:'end'});await wait('actual Manager observes real Worker end',()=>{check();return state.phase==='ended'&&!state.programAllowed;});
  await browser.until(g,"document.getElementById('preview').srcObject===null&&window.__fixtureCamera.every(s=>s.getTracks().every(t=>t.readyState==='ended'))",'actual ended guest stops generated capture');
  const ended={video:state.acceptedVideo,audio:state.audioAccepted};await pause(250);check();assert(state.acceptedVideo===ended.video&&state.audioAccepted===ended.audio,'No decoded ingress after actual room retirement');
  command({type:'stop'});await wait('actual native Manager/runtime terminal cleanup',()=>{check();return stopped&&closed;},10_000);assert(linesAfterStop===0&&browser.errors.length===0);
  await fs.writeFile(path.join(mediaDirectory,'proofs.json'),JSON.stringify({chrome:version.product,scope:'actual local Worker + owned UDP TURN; generated capture; default native Manager/receiver/controller Composer/mixer and Program/ISO',proofs},null,2)+'\n',{mode:0o600});
  console.log(`PASS ${version.product}: actual Manager default public-SDK receiver + controller-issued sink -> shipping Composer/mixer -> strict decoded Program and associated pinned ISO; real stage ACK, screen privacy, stable-slot fresh-lease rejoin and terminal retirement`);
  console.log('Scope: generated camera/screen/PCM, actual local Worker control and owned Coturn relay-only UDP with explicit local TURN override. No deployed broker, Internet/mobile, operator devices/TCC, mix-minus, physical hardware or signed-install qualification.');
} finally {
  browserSocket?.close();for(const value of children.reverse())await terminate(value);
  await fs.rm(owned,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
