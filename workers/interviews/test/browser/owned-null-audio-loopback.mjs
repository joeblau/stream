// Diagnostic only: owned generated stereo -> real Chromium RTC -> the exact
// null-context/muted-player WebAudio return consumer. No native SDK or output.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {spawn,execFile,execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {WebSocket} from 'ws';
import {chromeFixtureExecutable,chromeFixtureCredentialArguments} from './chrome-fixture.mjs';
import {captureLoopbackFailure} from './owned-loopback-failure-snapshot.mjs';
import {createLoopbackSignalJournal} from './owned-loopback-signal-journal.mjs';
import {createLoopbackTerminal,removeOwnedLoopbackDirectory} from './owned-loopback-lifecycle.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const artifact=process.env.STREAM_LOOPBACK_RECEIPT;
const fakeOutputClock=process.argv.includes('--fake-audio-output');
assert(artifact&&path.isAbsolute(artifact),'Set an absolute owned receipt path');
const temporaryRoot=await fs.realpath(os.tmpdir());
const owned=process.env.STREAM_LOOPBACK_OWNED_DIRECTORY
 ?await fs.realpath(process.env.STREAM_LOOPBACK_OWNED_DIRECTORY)
 :await fs.mkdtemp(path.join(temporaryRoot,'stream-owned-null-loopback-'));
const ownedInfo=await fs.lstat(owned,{bigint:true});
const ownedIdentity={device:ownedInfo.dev.toString(),inode:ownedInfo.ino.toString()};
assert(path.dirname(owned)===temporaryRoot&&path.basename(owned).startsWith('stream-owned-null-loopback-')&&
 ownedInfo.isDirectory()&&ownedInfo.uid===BigInt(process.getuid())&&(ownedInfo.mode&0o777n)===0o700n&&
 (await fs.readdir(owned)).length===0,'Use one fresh owned temporary directory');
if(process.env.STREAM_LOOPBACK_OWNED_IDENTITY)assert.deepEqual(ownedIdentity,JSON.parse(process.env.STREAM_LOOPBACK_OWNED_IDENTITY),'Owned directory incarnation changed');
let chrome,chromeIdentity,socket,server,cdp,receipt,progress,sessionId,lastProgress=Date.now(),traceEvents=[];
const processHelper=fileURLToPath(new URL('./owned_loopback_process.py',import.meta.url));
const terminal=createLoopbackTerminal(artifact);
const checkAbort=()=>{if(terminal.abortReason)throw new Error(terminal.abortReason);};
const abort=signal=>{terminal.abort(signal);cdp?.cancelPending(new Error(terminal.abortReason));if(!cdp)socket?.terminate();};
const interrupt=()=>abort('SIGINT'),terminate=()=>abort('SIGTERM');
process.on('SIGINT',interrupt);process.on('SIGTERM',terminate);
const phases=[],observations=[];
const source=await fs.readFile(fileURLToPath(new URL('./native-interview-return-video-browser.mjs',import.meta.url)),'utf8');
const meters=[...source.matchAll(/const returnMeterModule = `([\s\S]*?)`;/g)];
assert.equal(meters.length,1,'Exact existing production-path fixture worklet boundary');
const meter=meters[0][1];
const page=`<!doctype html><meta charset=utf-8><video id=return autoplay playsinline muted></video><script type=module src=/app.js></script>`;
const app=String.raw`
const captureLoopbackFailure=${captureLoopbackFailure.toString()};
const createLoopbackSignalJournal=${createLoopbackSignalJournal.toString()};
const emit=(kind,value)=>console.debug('owned-loopback',JSON.stringify({kind,value}));
let currentPhase='not-started',lastStageAt=performance.now();const pageBegan=lastStageAt;
const stage=value=>{currentPhase=value;lastStageAt=performance.now();emit('stage',value);};
const inPhase=async(name,action,announce=true)=>{
 if(announce)stage(name);else currentPhase=name;
 let timer;const remaining=Math.max(0,Math.min(16000-(performance.now()-lastStageAt),60000-(performance.now()-pageBegan)));
 try{return await Promise.race([Promise.resolve().then(action),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('owned-phase-deadline: '+name)),remaining);})]);}
 finally{clearTimeout(timer);}
};
const signaling=createLoopbackSignalJournal(()=>currentPhase);
const peers=[],contexts=[],tracks=[],htmlEvents=[],iceErrors=[];let senderPCM,receiverPCM,remoteTrack;
const player=document.getElementById('return');
window.__ownedLoopbackFailureSnapshot=()=>captureLoopbackFailure({phase:currentPhase,peers,contexts,track:remoteTrack,player,senderPCM,receiverPCM,iceErrors,signaling:signaling.snapshot()});
for(const name of ['play','playing','waiting','stalled','loadedmetadata','error'])player.addEventListener(name,()=>{if(htmlEvents.length<16){htmlEvents.push({name,muted:player.muted,paused:player.paused,readyState:player.readyState});emit('observer',{htmlEvent:htmlEvents.at(-1)});}});
const wait=async(predicate,ms=10000)=>{const end=performance.now()+ms;while(performance.now()<end){if(await predicate())return;await new Promise(r=>setTimeout(r,25));}throw new Error('owned-init-deadline');};
const sinkContext=async label=>{
  stage(label+'-constructor');const c=new AudioContext({sampleRate:48000,sinkId:{type:'none'}});contexts.push(c);
  if(c.sinkId?.type!=='none')throw new Error('null-sink-not-verified');
  await inPhase(label+'-resume',()=>c.resume());
  if(c.state!=='running')throw new Error('null-context-not-running');
  await inPhase(label+'-worklet',()=>c.audioWorklet.addModule('/meter.js'),false);stage(label+'-ready');return c;
};
const meterFor=(c,source,store,label)=>{let observed=false;const node=new AudioWorkletNode(c,'stream-owned-return-meter',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[2]}),silent=c.createGain();silent.gain.value=0;node.port.onmessage=e=>{store(e.data);if(!observed){observed=true;emit('observer',{worklet:label,frames:e.data.frames,channels:e.data.channels});}};source.connect(node);node.connect(silent).connect(c.destination);return node;};
const stats=async pc=>{
 const all=await pc.getStats(),result={outbound:[],inbound:[],playout:[],transport:[]};
 for(const r of all.values()){
  const codec=all.get(r.codecId);
  if(r.type==='outbound-rtp'&&r.kind==='audio')result.outbound.push({packetsSent:r.packetsSent,bytesSent:r.bytesSent,codec:codec?.mimeType,clockRate:codec?.clockRate,channels:codec?.channels,payloadType:codec?.payloadType});
  if(r.type==='inbound-rtp'&&r.kind==='audio')result.inbound.push({packetsReceived:r.packetsReceived,bytesReceived:r.bytesReceived,packetsLost:r.packetsLost,jitterBufferEmittedCount:r.jitterBufferEmittedCount,jitterBufferDelay:r.jitterBufferDelay,totalSamplesReceived:r.totalSamplesReceived,totalSamplesDuration:r.totalSamplesDuration,totalAudioEnergy:r.totalAudioEnergy,concealedSamples:r.concealedSamples,codec:codec?.mimeType,clockRate:codec?.clockRate,channels:codec?.channels,payloadType:codec?.payloadType});
  if(r.type==='media-playout')result.playout.push({kind:r.kind,synthesizedSamplesDuration:r.synthesizedSamplesDuration,synthesizedSamplesEvents:r.synthesizedSamplesEvents,totalSamplesDuration:r.totalSamplesDuration,totalPlayoutDelay:r.totalPlayoutDelay,totalSamplesCount:r.totalSamplesCount});
  if(r.type==='transport'&&r.selectedCandidatePairId){const pair=all.get(r.selectedCandidatePairId);result.transport.push({state:pair.state,local:all.get(pair.localCandidateId)?.candidateType,remote:all.get(pair.remoteCandidateId)?.candidateType});}
 }
 return result;
};
setTimeout(async()=>{try{
 if(!player.muted)throw new Error('owned-player-not-muted');
 stage('sender-context');const a=await sinkContext('sender');
 stage('receiver-context');const b=await sinkContext('receiver');
 const destination=a.createMediaStreamDestination(),merge=a.createChannelMerger(2);
 for(const [side,frequency,gain]of [[0,1000,.4],[1,1700,.2]]){const o=a.createOscillator(),g=a.createGain();o.frequency.value=frequency;g.gain.value=gain;o.connect(g).connect(merge,0,side);o.start();}
 merge.connect(destination);meterFor(a,merge,v=>senderPCM=v,'sender');
 const send=new RTCPeerConnection({iceServers:[]}),receive=new RTCPeerConnection({iceServers:[]});peers.push(send,receive);signaling.begin();
 for(const [peer,side]of [[send,'sender'],[receive,'receiver']])peer.addEventListener('icecandidateerror',event=>{if(iceErrors.length<8)iceErrors.push({side,code:event.errorCode});});
 const pendingSend=[],pendingReceive=[];
 send.onicecandidate=e=>{signaling.note('sender',e.candidate?'candidate-emitted':'candidate-end');if(e.candidate){if(receive.remoteDescription)signaling.observe('receiver','add-ice-candidate',()=>receive.addIceCandidate(e.candidate)).catch(error=>{if(iceErrors.length<8)iceErrors.push({side:'receiver',name:error.name});});else{signaling.note('receiver','candidate-queued');pendingReceive.push(e.candidate);}}};
 receive.onicecandidate=e=>{signaling.note('receiver',e.candidate?'candidate-emitted':'candidate-end');if(e.candidate){if(send.remoteDescription)signaling.observe('sender','add-ice-candidate',()=>send.addIceCandidate(e.candidate)).catch(error=>{if(iceErrors.length<8)iceErrors.push({side:'sender',name:error.name});});else{signaling.note('sender','candidate-queued');pendingSend.push(e.candidate);}}};
 receive.ontrack=e=>{stage('remote-track-before-html');remoteTrack=e.track;tracks.push(e.track);const stream=new MediaStream([e.track]);document.getElementById('return').srcObject=stream;stage('remote-track-before-webaudio');meterFor(b,b.createMediaStreamSource(new MediaStream([e.track])),v=>receiverPCM=v,'receiver');stage('remote-track-connected');};
 for(const track of destination.stream.getTracks()){tracks.push(track);send.addTrack(track,destination.stream);}
 const offer=await inPhase('create-offer',()=>signaling.observe('sender','create-offer',()=>send.createOffer()));await inPhase('sender-local-description',()=>signaling.observe('sender','set-local-description',()=>send.setLocalDescription(offer)));await inPhase('receiver-remote-description',()=>signaling.observe('receiver','set-remote-description',()=>receive.setRemoteDescription(send.localDescription)));
 await inPhase('receiver-pending-candidates',async()=>{for(const candidate of pendingReceive)await signaling.observe('receiver','add-ice-candidate',()=>receive.addIceCandidate(candidate));},false);
 const answer=await inPhase('create-answer',()=>signaling.observe('receiver','create-answer',()=>receive.createAnswer()));await inPhase('receiver-local-description',()=>signaling.observe('receiver','set-local-description',()=>receive.setLocalDescription(answer)));await inPhase('sender-remote-description',()=>signaling.observe('sender','set-remote-description',()=>send.setRemoteDescription(receive.localDescription)));
 await inPhase('sender-pending-candidates',async()=>{for(const candidate of pendingSend)await signaling.observe('sender','add-ice-candidate',()=>send.addIceCandidate(candidate));},false);stage('connection-wait');
 await wait(()=>send.connectionState==='connected'&&receive.connectionState==='connected'&&remoteTrack);
 stage('measuring');const started=performance.now();await new Promise(r=>setTimeout(r,12000));
 currentPhase='collecting-stats';
 const value={measurementMilliseconds:performance.now()-started,sender:await stats(send),receiver:await stats(receive),senderPCM,receiverPCM,contexts:contexts.map(c=>({state:c.state,sampleRate:c.sampleRate,sink:c.sinkId?.type,currentTime:c.currentTime})),track:{enabled:remoteTrack.enabled,muted:remoteTrack.muted,readyState:remoteTrack.readyState},html:{muted:document.getElementById('return').muted,events:htmlEvents},peerStates:peers.map(p=>p.connectionState)};
 emit('receipt',value);
 }catch(error){
  const snapshot=await window.__ownedLoopbackFailureSnapshot();
  emit('failure',{name:'OwnedInitializationFailure',message:error.message==='owned-init-deadline'?'owned-init-deadline':error.message?.startsWith('owned-phase-deadline: ')?'owned-phase-deadline':'owned-api-refusal',snapshot});
 }
 finally{signaling.retire();tracks.forEach(t=>t.stop());peers.forEach(p=>p.close());for(const c of contexts)c.close().catch(()=>{});}
},0);
`;
class CDP{
 constructor(ws){this.ws=ws;this.id=0;this.pending=new Map();this.events=[];this.traceBytes=0;ws.on('message',raw=>{const x=JSON.parse(raw),p=this.pending.get(x.id);if(p){this.pending.delete(x.id);clearTimeout(p.timer);x.error?p.reject(new Error(x.error.message)):p.resolve(x.result);}
  if(x.method==='Runtime.consoleAPICalled'&&x.params.args?.[0]?.value==='owned-loopback'){const event=JSON.parse(x.params.args[1].value);if(event.kind==='stage'){progress=event.value;lastProgress=Date.now();phases.push({phase:progress,time:Date.now()});console.log('Owned loopback phase: '+progress);}else if(event.kind==='observer'){if(observations.length<20){observations.push(event.value);console.log('Owned loopback observer: '+JSON.stringify(event.value));}}else if(event.kind==='receipt')receipt=event.value;else if(event.kind==='failure')throwFailure=event.value;}
  if(x.method==='Runtime.exceptionThrown')throwFailure={name:'RuntimeException',message:x.params.exceptionDetails.text};
  if(x.method==='Tracing.dataCollected'){this.traceBytes+=Buffer.byteLength(raw);if(this.traceBytes>8*1024*1024||traceEvents.length+x.params.value.length>25000)throwFailure={name:'TraceBudget',message:'bounded trace byte/count exceeded'};else traceEvents.push(...x.params.value);}
  if(x.method==='Tracing.tracingComplete')this.traceDone=true;
 });}
 send(method,params={},sessionId,deadline=10000){if(terminal.abortReason)return Promise.reject(new Error(terminal.abortReason));return new Promise((resolve,reject)=>{const id=++this.id,timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('CDP deadline: '+method));},deadline);this.pending.set(id,{resolve,reject,timer});this.ws.send(JSON.stringify({id,method,params,sessionId}));});}
 cancelPending(error){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(error);}this.pending.clear();}
 close(){this.cancelPending(new Error('Owned cleanup'));this.ws.close();}
}
let throwFailure,tracing=false;
const result={schemaVersion:1,kind:'owned-chrome-null-audio-loopback-diagnostic',scope:'Synthetic local RTC only; actual null WebAudio sinks + muted owned HTML. No native SDK, speaker/normal HTML output, AEC, AV or production qualification.',fakeOutputClockRequested:fakeOutputClock};
terminal.bind(result);
try{
 server=http.createServer((req,res)=>{res.setHeader('Content-Type',req.url==='/meter.js'||req.url==='/app.js'?'application/javascript':'text/html');res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; connect-src 'self'; media-src 'self' blob:");res.end(req.url==='/meter.js'?meter:req.url==='/app.js'?app:page);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const profile=path.join(owned,'profile');await fs.mkdir(profile,{mode:0o700});const binary=await chromeFixtureExecutable(process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',owned);
 checkAbort();
 const started=Date.now();
 chrome=spawn(binary,['--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--disable-background-networking','--disable-component-update','--disable-extensions','--autoplay-policy=no-user-gesture-required',...chromeFixtureCredentialArguments(),...(fakeOutputClock?['--disable-audio-output']:[]),'about:blank'],{detached:true,stdio:['ignore','ignore','pipe']});let stderr=0;chrome.stderr.on('data',b=>{stderr+=b.length;});
 chrome.on('error',()=>{throwFailure={name:'OwnedSpawnFailure',message:'owned-browser-spawn-refused'};});
 if(chrome.pid)chromeIdentity=JSON.parse(execFileSync('python3',[processHelper,'capture',String(chrome.pid),String(process.pid)],{encoding:'utf8',timeout:1000,maxBuffer:4096}));
 if(process.env.STREAM_LOOPBACK_PROCESS_MANIFEST){
  const target=process.env.STREAM_LOOPBACK_PROCESS_MANIFEST,temporary=target+'.new-'+process.pid;
  const encoded=JSON.stringify({nodePID:process.pid,chrome:chromeIdentity,ownedDirectory:owned,ownedIdentity,profile})+'\n';
  assert(Buffer.byteLength(encoded)<=4096,'Owned manifest exceeds budget');
  try{await fs.writeFile(temporary,encoded,{mode:0o600,flag:'wx'});await fs.link(temporary,target);}
  finally{await fs.rm(temporary,{force:true});}
 }
 let endpoint,monitorReady=!process.env.STREAM_LOOPBACK_MONITOR_READY;
 while((!endpoint||!monitorReady)&&Date.now()-started<10000){
  checkAbort();if(throwFailure)throw new Error(throwFailure.message);
  try{endpoint=(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).trim().split('\n');}catch{}
  if(!monitorReady){try{
   const encoded=await fs.readFile(process.env.STREAM_LOOPBACK_MONITOR_READY);assert(encoded.length<=4096,'Owned monitor receipt exceeds budget');
   const approval=JSON.parse(encoded);assert.equal(approval.nodePID,process.pid);assert.deepEqual(approval.chrome,chromeIdentity);assert.deepEqual(approval.ownedIdentity,ownedIdentity);monitorReady=true;
  }catch(error){if(error.code!=='ENOENT')throw error;}}
  if(!endpoint||!monitorReady)await pause(50);
 }
 assert(endpoint&&monitorReady,'Owned Chrome startup deadline');checkAbort();
 socket=new WebSocket(`ws://127.0.0.1:${endpoint[0]}${endpoint[1]}`,{handshakeTimeout:10000});await new Promise((r,j)=>{socket.once('open',r);socket.once('error',j);});cdp=new CDP(socket);
 result.browser=(await cdp.send('Browser.getVersion')).product;
 try{await cdp.send('Tracing.start',{categories:'audio,mediastream,disabled-by-default-mediastream',transferMode:'ReportEvents'});tracing=true;}catch{result.tracing='unavailable';}
 const {targetId}=await cdp.send('Target.createTarget',{url:'about:blank'});({sessionId}=await cdp.send('Target.attachToTarget',{targetId,flatten:true}));await cdp.send('Runtime.enable',{},sessionId);await cdp.send('Page.enable',{},sessionId);
 await cdp.send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`},sessionId);const began=Date.now();
 while(!receipt&&!throwFailure){checkAbort();if(Date.now()-began>60000||Date.now()-lastProgress>16000)throw new Error('Bounded initialization/measurement stall: '+progress);await pause(50);}checkAbort();
 if(throwFailure){result.initializationFailure=throwFailure;throw new Error(throwFailure.name+': '+throwFailure.message);}
 if(tracing){await cdp.send('Tracing.end');const end=Date.now()+5000;while(!cdp.traceDone&&Date.now()<end)await pause(25);assert(cdp.traceDone,'Trace completion deadline');}
 const names=['WebRtcAudioDeviceImpl::RenderData','VoE::PullRenderData','WebRtcAudioRenderer::Render','WebRtcAudioRenderer::SourceCallback','PeerConnectionRemoteAudioSource::OnData','WebAudioMediaStreamAudioSink::OnData','WebAudioMediaStreamAudioSink::ProvideInput','WebAudioMediaStreamAudioSink::ProvideInput underrun'];
 result.traceCounts=Object.fromEntries(names.map(name=>[name,traceEvents.filter(e=>e.name===name).length]));result.receipt=receipt;result.stderrBytes=stderr;
 assert(receipt.contexts.length===2&&receipt.contexts.every(c=>c.sink==='none'&&c.state==='running')&&receipt.html.muted,'Actual null sink and muted player boundary');
 assert(receipt.senderPCM?.frames>48000&&receipt.senderPCM.channels.every(c=>c.rms>.02),'Generated source actual PCM positive');
 assert(receipt.sender.outbound.some(r=>r.codec==='audio/opus'&&r.packetsSent>100),'Actual sender Opus packets positive');
 assert(receipt.receiver.inbound.some(r=>r.codec==='audio/opus'&&r.packetsReceived>100),'Actual receiver Opus RTP positive');
 const audio=receipt.receiver.inbound.find(r=>r.codec==='audio/opus');result.classification=audio.jitterBufferEmittedCount===0&&audio.totalSamplesReceived===0?'same-zero-emission-symptom':audio.totalSamplesReceived>0?'receiver-emitted-samples':'unclassified';
 terminal.complete();
}catch(error){
 result.result='UNQUALIFIED';result.phase=progress;result.reason=String(error.message).slice(0,160);process.exitCode=77;
 if(terminal.abortReason)result.failureSnapshot={status:'unavailable',reason:'owned-abort'};
 if(!terminal.abortReason&&!result.initializationFailure?.snapshot&&cdp&&sessionId){
  // Acceptance has already failed. This bounded read runs before CDP/peer
  // cleanup and never extends the original initialization or PCM gates.
  try{
   const captured=await cdp.send('Runtime.evaluate',{expression:'window.__ownedLoopbackFailureSnapshot?.()',awaitPromise:true,returnByValue:true},sessionId,700);
   result.failureSnapshot=captured.result?.value??{status:'unavailable'};
  }catch{result.failureSnapshot={status:'unavailable'};}
 }
 console.error(JSON.stringify(result,null,2));
}
finally{
 if(cdp){
   try{if(tracing&&!cdp.traceDone){await cdp.send('Tracing.end');const deadline=Date.now()+5000;while(!cdp.traceDone&&Date.now()<deadline)await pause(25);}}catch{}
   const names=['WebRtcAudioDeviceImpl::RenderData','VoE::PullRenderData','WebRtcAudioRenderer::Render','WebRtcAudioRenderer::SourceCallback','PeerConnectionRemoteAudioSource::OnData','WebAudioMediaStreamAudioSink::OnData','WebAudioMediaStreamAudioSink::ProvideInput','WebAudioMediaStreamAudioSink::ProvideInput underrun'];
   result.traceCounts=Object.fromEntries(names.map(name=>[name,traceEvents.filter(e=>e.name===name).length]));
   result.traceEventCount=traceEvents.length;result.traceBytes=cdp.traceBytes;result.traceComplete=cdp.traceDone===true;
   cdp.close();
 }
 result.observations=observations;
 result.phases=phases.map(({phase,time})=>({phase,milliseconds:time-(phases[0]?.time??time)}));
 if(chromeIdentity){
  try{result.processRetirement=(await new Promise((resolve,reject)=>{
   const retirement=execFile('python3',[processHelper,'retire'],{encoding:'utf8',timeout:5000,maxBuffer:4096},(error,stdout)=>error?reject(error):resolve(stdout));
   retirement.stdin.end(JSON.stringify(chromeIdentity));
  })).trim();}
  catch{result.processRetirement='unconfirmed';process.exitCode=77;result.result='UNQUALIFIED';}
  if(!['absent','drained'].includes(result.processRetirement)){process.exitCode=77;result.result='UNQUALIFIED';}
 }
 if(server){server.closeAllConnections();await new Promise(r=>server.close(r));}
 try{result.directoryRetirement=await removeOwnedLoopbackDirectory(owned,ownedIdentity);}
 catch{result.directoryRetirement='unconfirmed';}
 if(!['removed','absent'].includes(result.directoryRetirement)){process.exitCode=77;result.result='UNQUALIFIED';}
 await terminal.publish();
 console.log(JSON.stringify(result,null,2));
}
