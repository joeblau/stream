// Diagnostic only: owned generated stereo -> real Chromium RTC -> the exact
// null-context/muted-player WebAudio return consumer. No native SDK or output.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {WebSocket} from 'ws';
import {chromeFixtureExecutable,chromeFixtureCredentialArguments} from './chrome-fixture.mjs';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const owned=await fs.mkdtemp(path.join(os.tmpdir(),'stream-owned-null-loopback-'));
const artifact=process.env.STREAM_LOOPBACK_RECEIPT;
const fakeOutputClock=process.argv.includes('--fake-audio-output');
assert(artifact&&path.isAbsolute(artifact),'Set an absolute owned receipt path');
let chrome,socket,server,cdp,receipt,progress,lastProgress=Date.now(),traceEvents=[];
const phases=[],observations=[];
const source=await fs.readFile(fileURLToPath(new URL('./native-interview-return-video-browser.mjs',import.meta.url)),'utf8');
const meters=[...source.matchAll(/const returnMeterModule = `([\s\S]*?)`;/g)];
assert.equal(meters.length,1,'Exact existing production-path fixture worklet boundary');
const meter=meters[0][1];
const page=`<!doctype html><meta charset=utf-8><video id=return autoplay playsinline muted></video><script type=module src=/app.js></script>`;
const app=String.raw`
const emit=(kind,value)=>console.debug('owned-loopback',JSON.stringify({kind,value}));
const stage=value=>emit('stage',value);
const peers=[],contexts=[],tracks=[],htmlEvents=[],iceErrors=[];let senderPCM,receiverPCM,remoteTrack;
const player=document.getElementById('return');
for(const name of ['play','playing','waiting','stalled','loadedmetadata','error'])player.addEventListener(name,()=>{if(htmlEvents.length<16){htmlEvents.push({name,muted:player.muted,paused:player.paused,readyState:player.readyState});emit('observer',{htmlEvent:htmlEvents.at(-1)});}});
const wait=async(predicate,ms=10000)=>{const end=performance.now()+ms;while(performance.now()<end){if(await predicate())return;await new Promise(r=>setTimeout(r,25));}throw new Error('owned-init-deadline');};
const sinkContext=async label=>{
  stage(label+'-constructor');const c=new AudioContext({sampleRate:48000,sinkId:{type:'none'}});contexts.push(c);
  if(c.sinkId?.type!=='none')throw new Error('null-sink-not-verified');
  stage(label+'-resume');await c.resume();
  if(c.state!=='running')throw new Error('null-context-not-running');
  await c.audioWorklet.addModule('/meter.js');stage(label+'-ready');return c;
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
 stage('sender-context');const a=await sinkContext('sender');
 stage('receiver-context');const b=await sinkContext('receiver');
 const destination=a.createMediaStreamDestination(),merge=a.createChannelMerger(2);
 for(const [side,frequency,gain]of [[0,1000,.4],[1,1700,.2]]){const o=a.createOscillator(),g=a.createGain();o.frequency.value=frequency;g.gain.value=gain;o.connect(g).connect(merge,0,side);o.start();}
 merge.connect(destination);meterFor(a,merge,v=>senderPCM=v,'sender');
 const send=new RTCPeerConnection({iceServers:[]}),receive=new RTCPeerConnection({iceServers:[]});peers.push(send,receive);
 const pendingSend=[],pendingReceive=[];
 send.onicecandidate=e=>{if(e.candidate){if(receive.remoteDescription)receive.addIceCandidate(e.candidate).catch(error=>{if(iceErrors.length<8)iceErrors.push({side:'receiver',name:error.name});});else pendingReceive.push(e.candidate);}};
 receive.onicecandidate=e=>{if(e.candidate){if(send.remoteDescription)send.addIceCandidate(e.candidate).catch(error=>{if(iceErrors.length<8)iceErrors.push({side:'sender',name:error.name});});else pendingSend.push(e.candidate);}};
 receive.ontrack=e=>{stage('remote-track-before-html');remoteTrack=e.track;tracks.push(e.track);const stream=new MediaStream([e.track]);document.getElementById('return').srcObject=stream;stage('remote-track-before-webaudio');meterFor(b,b.createMediaStreamSource(new MediaStream([e.track])),v=>receiverPCM=v,'receiver');stage('remote-track-connected');};
 for(const track of destination.stream.getTracks()){tracks.push(track);send.addTrack(track,destination.stream);}
 stage('create-offer');const offer=await send.createOffer();stage('sender-local-description');await send.setLocalDescription(offer);stage('receiver-remote-description');await receive.setRemoteDescription(send.localDescription);for(const candidate of pendingReceive)await receive.addIceCandidate(candidate);
 stage('create-answer');const answer=await receive.createAnswer();stage('receiver-local-description');await receive.setLocalDescription(answer);stage('sender-remote-description');await send.setRemoteDescription(receive.localDescription);for(const candidate of pendingSend)await send.addIceCandidate(candidate);stage('connection-wait');
 await wait(()=>send.connectionState==='connected'&&receive.connectionState==='connected'&&remoteTrack);
 stage('measuring');const started=performance.now();await new Promise(r=>setTimeout(r,12000));
 const value={measurementMilliseconds:performance.now()-started,sender:await stats(send),receiver:await stats(receive),senderPCM,receiverPCM,contexts:contexts.map(c=>({state:c.state,sampleRate:c.sampleRate,sink:c.sinkId?.type,currentTime:c.currentTime})),track:{enabled:remoteTrack.enabled,muted:remoteTrack.muted,readyState:remoteTrack.readyState},html:{muted:document.getElementById('return').muted,events:htmlEvents},peerStates:peers.map(p=>p.connectionState)};
 emit('receipt',value);
 }catch(error){emit('failure',{name:error.name,message:String(error.message).slice(0,80),iceErrors,
  peers:peers.map(p=>({connection:p.connectionState,iceConnection:p.iceConnectionState,iceGathering:p.iceGatheringState,signaling:p.signalingState,
    localCandidateCount:(p.localDescription?.sdp.match(/^a=candidate:/gm)||[]).length,remoteCandidateCount:(p.remoteDescription?.sdp.match(/^a=candidate:/gm)||[]).length}))});}
 finally{tracks.forEach(t=>t.stop());peers.forEach(p=>p.close());for(const c of contexts)c.close().catch(()=>{});}
},0);
`;
class CDP{
 constructor(ws){this.ws=ws;this.id=0;this.pending=new Map();this.events=[];this.traceBytes=0;ws.on('message',raw=>{const x=JSON.parse(raw),p=this.pending.get(x.id);if(p){this.pending.delete(x.id);clearTimeout(p.timer);x.error?p.reject(new Error(x.error.message)):p.resolve(x.result);}
  if(x.method==='Runtime.consoleAPICalled'&&x.params.args?.[0]?.value==='owned-loopback'){const event=JSON.parse(x.params.args[1].value);if(event.kind==='stage'){progress=event.value;lastProgress=Date.now();phases.push({phase:progress,time:Date.now()});console.log('Owned loopback phase: '+progress);}else if(event.kind==='observer'){if(observations.length<20){observations.push(event.value);console.log('Owned loopback observer: '+JSON.stringify(event.value));}}else if(event.kind==='receipt')receipt=event.value;else if(event.kind==='failure')throwFailure=event.value;}
  if(x.method==='Runtime.exceptionThrown')throwFailure={name:'RuntimeException',message:x.params.exceptionDetails.text};
  if(x.method==='Tracing.dataCollected'){this.traceBytes+=Buffer.byteLength(raw);if(this.traceBytes>8*1024*1024||traceEvents.length+x.params.value.length>25000)throwFailure={name:'TraceBudget',message:'bounded trace byte/count exceeded'};else traceEvents.push(...x.params.value);}
  if(x.method==='Tracing.tracingComplete')this.traceDone=true;
 });}
 send(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++this.id,timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('CDP deadline: '+method));},10000);this.pending.set(id,{resolve,reject,timer});this.ws.send(JSON.stringify({id,method,params,sessionId}));});}
 close(){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Error('Owned cleanup'));}this.pending.clear();this.ws.close();}
}
let throwFailure,tracing=false;
const result={schemaVersion:1,kind:'owned-chrome-null-audio-loopback-diagnostic',scope:'Synthetic local RTC only; actual null WebAudio sinks + muted owned HTML. No native SDK, speaker/normal HTML output, AEC, AV or production qualification.',fakeOutputClockRequested:fakeOutputClock};
try{
 server=http.createServer((req,res)=>{res.setHeader('Content-Type',req.url==='/meter.js'||req.url==='/app.js'?'application/javascript':'text/html');res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; connect-src 'self'; media-src 'self' blob:");res.end(req.url==='/meter.js'?meter:req.url==='/app.js'?app:page);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const profile=path.join(owned,'profile');await fs.mkdir(profile,{mode:0o700});const binary=await chromeFixtureExecutable(process.env.CHROME_BIN??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',owned);
 chrome=spawn(binary,['--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run','--disable-background-networking','--disable-component-update','--disable-extensions','--autoplay-policy=no-user-gesture-required',...chromeFixtureCredentialArguments(),...(fakeOutputClock?['--disable-audio-output']:[]),'about:blank'],{detached:true,stdio:['ignore','ignore','pipe']});let stderr=0;chrome.stderr.on('data',b=>{stderr+=b.length;});
 const started=Date.now();let endpoint;while(!endpoint&&Date.now()-started<10000){try{endpoint=(await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).trim().split('\n');}catch{await pause(50);}}assert(endpoint,'Owned Chrome startup deadline');
 socket=new WebSocket(`ws://127.0.0.1:${endpoint[0]}${endpoint[1]}`,{handshakeTimeout:10000});await new Promise((r,j)=>{socket.once('open',r);socket.once('error',j);});cdp=new CDP(socket);
 result.browser=(await cdp.send('Browser.getVersion')).product;
 try{await cdp.send('Tracing.start',{categories:'audio,mediastream,disabled-by-default-mediastream',transferMode:'ReportEvents'});tracing=true;}catch{result.tracing='unavailable';}
 const {targetId}=await cdp.send('Target.createTarget',{url:'about:blank'}),{sessionId}=await cdp.send('Target.attachToTarget',{targetId,flatten:true});await cdp.send('Runtime.enable',{},sessionId);await cdp.send('Page.enable',{},sessionId);
 await cdp.send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`},sessionId);const began=Date.now();
 while(!receipt&&!throwFailure){if(Date.now()-began>60000||Date.now()-lastProgress>16000)throw new Error('Bounded initialization/measurement stall: '+progress);await pause(50);}
 if(throwFailure){result.initializationFailure=throwFailure;throw new Error(throwFailure.name+': '+throwFailure.message);}
 if(tracing){await cdp.send('Tracing.end');const end=Date.now()+5000;while(!cdp.traceDone&&Date.now()<end)await pause(25);assert(cdp.traceDone,'Trace completion deadline');}
 const names=['WebRtcAudioDeviceImpl::RenderData','VoE::PullRenderData','WebRtcAudioRenderer::Render','WebRtcAudioRenderer::SourceCallback','PeerConnectionRemoteAudioSource::OnData','WebAudioMediaStreamAudioSink::OnData','WebAudioMediaStreamAudioSink::ProvideInput','WebAudioMediaStreamAudioSink::ProvideInput underrun'];
 result.traceCounts=Object.fromEntries(names.map(name=>[name,traceEvents.filter(e=>e.name===name).length]));result.receipt=receipt;result.stderrBytes=stderr;
 assert(receipt.contexts.length===2&&receipt.contexts.every(c=>c.sink==='none'&&c.state==='running')&&receipt.html.muted,'Actual null sink and muted player boundary');
 assert(receipt.senderPCM?.frames>48000&&receipt.senderPCM.channels.every(c=>c.rms>.02),'Generated source actual PCM positive');
 assert(receipt.sender.outbound.some(r=>r.codec==='audio/opus'&&r.packetsSent>100),'Actual sender Opus packets positive');
 assert(receipt.receiver.inbound.some(r=>r.codec==='audio/opus'&&r.packetsReceived>100),'Actual receiver Opus RTP positive');
 const audio=receipt.receiver.inbound.find(r=>r.codec==='audio/opus');result.classification=audio.jitterBufferEmittedCount===0&&audio.totalSamplesReceived===0?'same-zero-emission-symptom':audio.totalSamplesReceived>0?'receiver-emitted-samples':'unclassified';
 result.result='DIAGNOSTIC_COMPLETE';console.log(JSON.stringify(result,null,2));
}catch(error){result.result='UNQUALIFIED';result.phase=progress;result.reason=String(error.message).slice(0,160);process.exitCode=77;console.error(JSON.stringify(result,null,2));}
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
 if(chrome?.exitCode===null){try{process.kill(-chrome.pid,'SIGTERM');}catch{}await Promise.race([new Promise(r=>chrome.once('close',r)),pause(2000)]);if(chrome.exitCode===null){try{process.kill(-chrome.pid,'SIGKILL');}catch{}}}
 if(server)await new Promise(r=>server.close(r));await fs.writeFile(artifact,JSON.stringify(result,null,2)+'\n',{mode:0o600});await fs.rm(owned,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
