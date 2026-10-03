// Actual local Worker control + owned Coturn relay + shipping native session,
// receiver adapter and leased sink. Generated capture inputs only, no devices.
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {WebSocket} from 'ws';
import {chromeFixtureExecutable, chromeFixtureCredentialArguments, ChromeFixtureDiagnostics} from './chrome-fixture.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const startup=new ChromeFixtureDiagnostics();
async function wait(label,predicate,timeout=15_000){const end=Date.now()+timeout;while(Date.now()<end){const value=await predicate();if(value)return value;await pause(50);}throw new Error(`Bounded fixture timeout: ${label}`);}
async function port(){const server=net.createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const value=server.address().port;await new Promise(resolve=>server.close(resolve));return value;}
const workerRoot=fileURLToPath(new URL('../../',import.meta.url));
const cli=process.env.NATIVE_INTERVIEW_MEDIA_CLI, turnserver=process.env.STREAM_INTERVIEW_TURN_SERVER;
const expectPolicyUnavailable=process.argv.slice(2).includes('--expect-relay-policy-unavailable');
const tcpOnly=process.argv.slice(2).includes('--policy-tcp-only'),tcpProbe=process.env.STREAM_RELAY_POLICY_TCP_PROBE;
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
const paint=()=>{context.fillStyle=color;context.fillRect(0,0,320,180);context.fillStyle='white';context.fillRect((counter++%80)*4,0,4,4);};paint();
const stream=canvas.captureStream(15),track=stream.getVideoTracks()[0];const timer=setInterval(()=>{if(track.readyState==='ended'){clearInterval(timer);return;}paint();},60);return stream;};
Object.defineProperty(navigator.mediaDevices,'enumerateDevices',{value:async()=>[]});
Object.defineProperty(navigator.mediaDevices,'getUserMedia',{value:async()=>{const camera=canvasTrack('rgb(220,20,15)');window.__fixtureCamera.push(camera);
const context=new AudioContext({sampleRate:48000});await context.resume();const destination=context.createMediaStreamDestination(),merge=context.createChannelMerger(2);
for(const [channel,frequency]of [[0,440],[1,880]]){const oscillator=context.createOscillator(),gain=context.createGain();oscillator.frequency.value=frequency;gain.gain.value=channel===0?.14:.07;oscillator.connect(gain).connect(merge,0,channel);oscillator.start();}
merge.connect(destination);window.__fixtureAudio.push({context,stream:destination.stream});destination.stream.getTracks()[0].addEventListener('ended',()=>context.close());return new MediaStream([...camera.getTracks(),...destination.stream.getTracks()]);}});
Object.defineProperty(navigator.mediaDevices,'getDisplayMedia',{value:async()=>{const stream=canvasTrack('rgb(15,20,220)');window.__fixtureScreens.push(stream);return stream;}});
`;

try {
  const servicePort=await port(),inspectorPort=await port(),turnPort=await port();
  const origin=`http://127.0.0.1:${servicePort}`;
  const operatorToken=randomBytes(32).toString('hex'),turnUsername=randomBytes(16).toString('hex'),turnCredential=randomBytes(32).toString('hex');
  const turnURL=`turn:127.0.0.1:${turnPort}?transport=udp`;
  const workerConfig={name:'native-session-relay-validation',main:path.join(workerRoot,'src/index.ts'),compatibility_date:'2026-10-02',compatibility_flags:['nodejs_compat'],durable_objects:{bindings:[{name:'ROOMS',class_name:'InterviewRoom'}]},migrations:[{tag:'v1',new_sqlite_classes:['InterviewRoom']}],assets:{directory:path.join(workerRoot,'public'),binding:'ASSETS',run_worker_first:true},vars:{OPERATOR_TOKEN:operatorToken,ALLOWED_ORIGIN:origin,TURN_KEY_ID:''},observability:{enabled:false}};
  const config=path.join(owned,'wrangler.json'),relayConfig=path.join(owned,'turnserver.conf'),nativeConfig=path.join(owned,'native.json');
  await fs.writeFile(config,JSON.stringify(workerConfig),{mode:0o600});
  await fs.writeFile(nativeConfig,JSON.stringify({serviceURL:origin,operatorToken,turnURL,turnUsername,turnCredential}),{mode:0o600});
  await fs.writeFile(relayConfig,[`listening-port=${turnPort}`,'listening-ip=127.0.0.1','relay-ip=127.0.0.1','min-port=49160','max-port=49175','realm=owned-fixture.invalid','lt-cred-mech',`user=${turnUsername}:${turnCredential}`,'fingerprint','allow-loopback-peers','allowed-peer-ip=127.0.0.1','denied-peer-ip=0.0.0.0-255.255.255.255','no-multicast-peers','no-tcp','no-tls','no-tcp-relay','no-stdout-log','log-file=/dev/null',`pidfile=${path.join(owned,'turn.pid')}`,`userdb=${path.join(owned,'turn.db')}`,'relay-threads=1','cpus=2','user-quota=8','total-quota=8','max-allocate-lifetime=120','max-bps=1048576','bps-capacity=8388608'].join('\n')+'\n',{mode:0o600});
  turn=child(turnserver,['-c',relayConfig]);
  if(tcpProbe){
    assert(path.isAbsolute(tcpProbe),'Use an absolute owned public-API TCP probe');await fs.access(tcpProbe,fs.constants.X_OK);
    const probe=child(tcpProbe,[],{stdio:['pipe','pipe','ignore']});let output='';
    probe.stdout.on('data',chunk=>{output+=chunk.toString('utf8');if(output.length>4096)failure=new Error('TCP policy metadata exceeded budget');});
    probe.stdin.on('error',()=>{failure=new Error('TCP policy input closed');});
    probe.stdin.end(`${turnPort}\n${turnUsername}\n${turnCredential}\n`);
    const result=await Promise.race([new Promise(resolve=>probe.once('close',resolve)),pause(10_000).then(()=>undefined)]);
    for(const line of output.trim().split('\n')){
      assert(/^(PASS|FAIL): actual (All|Relay) ICE-TCP active, TURN relay gathered, owned remote TCP listener (connected|unconnected)$/.test(line),'Only allowlisted TCP metadata may be logged');console.log(line);
    }
    check();assert(result===0,'Actual public relay policy TCP fixture failed or exceeded deadline');
  }
  if(tcpOnly){assert(tcpProbe,'TCP-only fixture needs its actual compiled public-API probe');console.log('Scope: owned local TURN + public ICE API and loopback TCP listener only; no browser media or deployed service qualification.');}
  else {
  worker=child(process.execPath,[path.join(workerRoot,'node_modules/wrangler/bin/wrangler.js'),'dev','--local','--config',config,'--ip','127.0.0.1','--port',String(servicePort),'--inspector-port',String(inspectorPort),'--persist-to',path.join(owned,'state'),'--log-level','none','--show-interactive-dev-session=false']);
  await wait('real local Worker readiness',async()=>{check();try{return(await fetch(`${origin}/guest.html`,{signal:AbortSignal.timeout(1000)})).status===200;}catch{return false;}},20_000);
  assert(turn.exitCode===null,'Owned Coturn must remain running');
  let pending='',nativeBytes=0,stderrBytes=0,state,invite,accepted,stopped=false,closed=false,linesAfterStop=0;
  native=child(cli,[nativeConfig],{stdio:['pipe','pipe','pipe']});
  native.stdin.on('error',()=>{failure=new Error('Native command pipe closed');});
  native.stderr.on('data',chunk=>{stderrBytes+=chunk.length;if(stderrBytes>262_144)failure=new Error('Native diagnostic budget exceeded');});
  native.on('close',code=>{closed=true;if(!stopped||code!==0)failure=new Error('Native process failed before terminal receipt');});
  native.stdout.on('data',chunk=>{
    nativeBytes+=chunk.length;if(pending.length+chunk.length>65_536){failure=new Error('Native receipt backlog exceeded');return;}
    pending+=chunk.toString('utf8');let newline;
    while((newline=pending.indexOf('\n'))!==-1){const line=pending.slice(0,newline);pending=pending.slice(newline+1);try{
      assert(line.length<=16_384,'Native receipt bound');const value=JSON.parse(line);
      if(stopped){linesAfterStop++;throw new Error('Native emitted after stopped');}
      switch(value.type){
        case'private-invite':assert(!invite&&typeof value.url==='string'&&value.url.length<=2048,'Private invite IPC shape');invite=value.url;break;
        case'state':assert(typeof value.phase==='string'&&Array.isArray(value.members)&&value.members.length<=1,'Native state shape');state=value;break;
        case'accepted':assert(Number.isSafeInteger(value.generation)&&value.generation>0&&Array.isArray(value.roles)&&value.roles.length===3,'Native accepted lease shape');accepted=value;break;
        case'stopped':stopped=true;break;
        case'error':throw new Error(`Native safe error: ${/^[a-zA-Z]{1,32}$/.test(value.reason)?value.reason:'unknown'}`);
        default:throw new Error('Unknown native receipt');
      }
    }catch(error){failure=new Error(String(error.message).slice(0,160));}}
  });
  function command(value){check();assert(native.stdin.writableLength<16_384,'Native command backlog');native.stdin.write(JSON.stringify(value)+'\n');}
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
  const role=name=>accepted?.roles.find(value=>value.role===name);
  await wait('actual relay-only native H264 and Opus sink acceptance OR strict policy failure',()=>{check();return state?.failure==='unavailable'||state?.members[0]?.media==='ready'&&role('camera')?.count>=4&&role('audio')?.samples>=4800;},20_000);
  if(state.failure==='unavailable') {
    assert(expectPolicyUnavailable,'Pinned SDK selected a non-relay native socket; positive both-local-relay qualification remains UNMET');
    assert(state.members[0]?.media==='failed'&&accepted?.roles.every(value=>value.count===0&&value.samples===0),'Strict selected-relay policy must fail before ready or ANY native sink media');
    command({type:'end'});await wait('policy-failed room ends through actual Worker',()=>{check();return state?.phase==='ended';});
    await browser.until(g,"document.getElementById('preview').srcObject===null&&window.__fixtureCamera.every(s=>s.getTracks().every(t=>t.readyState==='ended'))",'policy-failed guest stops capture');
    command({type:'stop'});await wait('policy-failed native retires without late receipt',()=>{check();return stopped&&closed;},10_000);assert(linesAfterStop===0);
    console.log(`PASS NEGATIVE ${version.product}: actual local Worker + owned TURN, pinned SDK non-relay native selection fails unavailable BEFORE ready/accepted pixels/PCM; actual room end retires browser and native`);
    console.log('UNMET: positive both-endpoint selected-local-relay media policy; no relay-only production media, deployed broker, Internet/mobile, UI or Program qualification from this failure fixture.');
  } else {
  assert(!expectPolicyUnavailable,'Expected the reproduced pinned SDK non-relay policy failure');
  const rgb=role('camera').rgb;assert(rgb[0]>150&&rgb[1]<80&&rgb[2]<80,'Actual accepted native camera is red');
  assert(role('audio').rms.length===2&&role('audio').rms[0]>.01&&role('audio').rms[1]>.005,'Real native stereo PCM contains generated tone');
  const ratio=role('audio').rms[0]/role('audio').rms[1];assert(ratio>1.3&&ratio<3,'Actual native PCM retains distinct stereo channels');
  assert(role('screen').count===0,'Screen default deny');
  const pair=await browser.evaluate(g,`(async()=>{const pc=window.__fixturePeers.at(-1),stats=await pc.getStats();for(const transport of stats.values()){if(transport.type==='transport'&&transport.selectedCandidatePairId){const pair=stats.get(transport.selectedCandidatePairId),local=stats.get(pair.localCandidateId),remote=stats.get(pair.remoteCandidateId);return{local:local.candidateType,remote:remote.candidateType,protocol:local.protocol,sent:pair.bytesSent,received:pair.bytesReceived};}}return null;})()`);
  console.log(`Owned relay pair metadata: ${JSON.stringify(pair)}`);
  console.log(`Owned initial native pair metadata: ${JSON.stringify(state?.transport??null)}`);
  await wait('actual native selected local relay candidate',()=>{check();return state?.transport?.local==='relay';});
  console.log(`Owned native selected pair metadata: ${JSON.stringify(state.transport)}`);
  assert(pair?.local==='relay'&&pair.sent>0&&pair.received>0&&state.transport.local==='relay'&&state.transport.udp,'Both actual endpoints must select local TURN relay candidates and deliver actual media');
  console.log(`PASS actual local Worker + ${version.product} -> native production adapter/leased sink: both selected LOCAL candidates relay ${pair.protocol}, Chrome remote=${pair.remote}; H264 camera and stereo48k Opus PCM; no early media or screen admission`);
  command({type:'approval',id:guest,approved:true});await browser.until(g,"!document.getElementById('share').disabled",'native actual approval channel');
  await browser.evaluate(g,"document.getElementById('share').click()");await wait('simultaneous native camera/screen/audio accepted',()=>{check();return role('screen')?.count>=3&&state?.members[0]?.sharing;},20_000);
  const blue=role('screen').rgb;assert(blue[2]>150&&blue[0]<80,'Actual native screen is blue');
  const cameraBefore=role('camera').count,audioBefore=role('audio').samples;
  await browser.evaluate(g,"document.getElementById('stopshare').click()");await browser.until(g,"window.__fixtureScreens.every(s=>s.getTracks().every(t=>t.readyState==='ended'))",'screen stops independently');
  command({type:'approval',id:guest,approved:false});await wait('native screen grant revoked',()=>{check();return state?.members[0]?.approved===false&&state.members[0].sharing===false;});
  const screenStopped=role('screen').count;await pause(350);check();assert(role('screen').count===screenStopped,'No accepted screen after synchronous revocation');
  assert(role('camera').count>cameraBefore&&role('audio').samples>audioBefore,'Camera/audio remain healthy after screen stop');
  console.log('PASS actual native approval and independent screen stop: real separate MID pixels, strict revoked sink and healthy camera/audio');
  const original={generation:accepted.generation,negotiation:accepted.negotiation,slot:accepted.slot};
  command({type:'rejoin'});await wait('native host explicitly rejoined service',()=>{check();return state?.phase==='connected'&&state.members[0]?.membership==='waiting';});
  command({type:'admit',id:guest});await wait('new native relay peer and original stable slot',()=>{check();return accepted?.generation>original.generation&&state?.members[0]?.media==='ready'&&role('camera')?.count>=3&&role('audio')?.samples>=2880;},20_000);
  assert(accepted.slot===original.slot&&accepted.negotiation!==original.negotiation,'Rejoin must retain stable slot and replace full authority');
  assert(role('screen').count===0&&state.members[0].approved===false,'Rejoin cannot inherit screen permission');
  command({type:'end'});await wait('native observes actual Worker end',()=>{check();return state?.phase==='ended';});
  await browser.until(g,"document.getElementById('preview').srcObject===null&&document.getElementById('prepare').disabled&&window.__fixtureCamera.every(s=>s.getTracks().every(t=>t.readyState==='ended'))",'real ended event stops generated guest capture');
  const endCount=accepted.roles.map(value=>value.count);await pause(250);check();assert(accepted.roles.every((value,index)=>value.count===endCount[index]),'No sink media after room end');
  command({type:'stop'});await wait('native synchronous gates and terminal receipt',()=>{check();return stopped&&closed;},10_000);assert(linesAfterStop===0,'No native receipt after stopped');
  assert(browser.errors.length===0,'Actual guest lifecycle has no browser exception');
  console.log('PASS actual service rejoin/end + native receiver retirement: fresh full lease, stable source slot, grants reset, terminal browser tracks/process and no late accepted receipt');
  console.log('Scope: owned local Worker control and local Coturn relay-only UDP; generated capture inputs, actual public SDK/Apple codecs and registered sink. Explicit local TURN override, no deployed broker, Internet/mobile, shipping UI/Controller, Program/mix-minus or signed install qualification.');
  }
  }
} finally {
  browserSocket?.close();for(const value of children.reverse())await terminate(value);
  await fs.rm(owned,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
