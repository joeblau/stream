import assert from 'node:assert/strict';
import {test} from 'node:test';
import vm from 'node:vm';
import fs from 'node:fs/promises';
import {captureLoopbackFailure} from './owned-loopback-failure-snapshot.mjs';

const secret='PRIVATE_SDP_IP_CREDENTIAL_PAYLOAD';
function peer(report=new Map()) {
  return {connectionState:'connecting',iceConnectionState:'checking',iceGatheringState:'complete',signalingState:'stable',
    localDescription:{sdp:'a=candidate:'+secret+'\r\n'},remoteDescription:{sdp:'a=candidate:'+secret+'\r\n'},
    getStats:async()=>report};
}

test('bounded allowlist preserves diagnostic counters and excludes identifiers, addresses and payloads',async()=>{
  const report=new Map([
    ['codec',{mimeType:'audio/opus',clockRate:48000,channels:2,payloadType:111,sdpFmtpLine:secret}],
    ['audio',{type:'inbound-rtp',kind:'audio',codecId:'codec',packetsReceived:931,jitterBufferEmittedCount:0,
      totalSamplesReceived:0,totalAudioEnergy:0,bytesReceived:151615,trackIdentifier:secret,privatePayload:secret}],
    ['send',{type:'outbound-rtp',kind:'audio',codecId:'codec',packetsSent:933,bytesSent:151800}],
    ['transport',{type:'transport',selectedCandidatePairId:'pair',tlsVersion:secret}],
    ['pair',{state:'succeeded',localCandidateId:'local',remoteCandidateId:'remote',address:secret}],
    ['local',{candidateType:'host',address:secret,port:12345,usernameFragment:secret}],
    ['remote',{candidateType:'relay',address:secret,url:secret}],
    ['playout',{type:'media-playout',kind:'audio',totalSamplesCount:0,totalSamplesDuration:0,id:secret}]
  ]);
  const receipt=await captureLoopbackFailure({phase:'connection-wait',peers:[peer(report)],
    contexts:[{state:'running',sampleRate:48000,currentTime:1.5,sinkId:{type:'none'},deviceId:secret}],
    track:{enabled:true,muted:false,readyState:'live',id:secret},player:{muted:true,paused:false,readyState:4,currentTime:2,src:secret},
    senderPCM:{frames:2048,rate:48000,channels:[{rms:.28,amplitudes:[.4,0,0,0],samples:secret}]},
    receiverPCM:{frames:2048,channels:[{rms:0,amplitudes:[0,0,0,0]}]},
    iceErrors:[{side:'receiver',name:'OperationError',code:701,errorText:secret,url:secret}]});
  assert.equal(receipt.phase,'connection-wait');
  assert.equal(receipt.peers[0].localCandidateCount,1);
  assert.equal(receipt.stats[0].inbound[0].packetsReceived,931);
  assert.equal(receipt.stats[0].inbound[0].jitterBufferEmittedCount,0);
  assert.deepEqual(receipt.stats[0].transport,[{state:'succeeded',local:'host',remote:'relay'}]);
  assert.equal(receipt.contexts[0].nullSink,true);
  assert.equal(receipt.senderPCM.channels[0].amplitudes[0],.4);
  assert(!JSON.stringify(receipt).includes(secret));
});

test('states, candidates, errors, report rows and PCM arrays have fixed bounds',async()=>{
  const report=new Map(Array.from({length:1000},(_,i)=>[i,{type:'inbound-rtp',kind:'audio',packetsReceived:i,
    bytesReceived:Infinity,totalSamplesReceived:-1,codecId:'absent'}]));
  const source=peer(report);source.connectionState=secret;source.localDescription.sdp=('a=candidate:'+secret+'\n').repeat(1000);
  const receipt=await captureLoopbackFailure({phase:secret,peers:Array(100).fill(source),contexts:Array(100).fill({}),
    iceErrors:Array(100).fill({side:secret,name:secret,code:Infinity}),
    senderPCM:{channels:Array(100).fill({rms:NaN,amplitudes:Array(100).fill(Infinity)})}});
  assert.equal(receipt.phase,'unknown');assert.equal(receipt.peers.length,2);
  assert.equal(receipt.peers[0].connection,'unknown');assert.equal(receipt.peers[0].localCandidateCount,128);
  assert.equal(receipt.stats[0].inbound.length,2);assert.equal(receipt.contexts.length,2);
  assert.equal(receipt.iceErrors.length,8);assert.equal(receipt.senderPCM.channels.length,2);
  assert.deepEqual(receipt.senderPCM.channels[0].amplitudes,[null,null,null,null]);
  assert.equal(receipt.stats[0].inbound[0].bytesReceived,undefined);
  assert.equal(receipt.stats[0].inbound[0].totalSamplesReceived,undefined);
  assert(!JSON.stringify(receipt).includes(secret));assert(JSON.stringify(receipt).length<6000);
});

test('snapshot freezes pre-cleanup states and retains completed stats when another peer stalls',async()=>{
  const first=peer(),second=peer();let finish;
  second.getStats=()=>new Promise(resolve=>{finish=resolve;});
  const began=performance.now();
  const pending=captureLoopbackFailure({phase:'sender-remote-description',peers:[first,second]});
  // Model retirement while asynchronous stats are pending: the captured
  // synchronous evidence must still describe the pre-retirement boundary.
  first.connectionState='closed';second.connectionState='closed';
  const receipt=await pending;
  assert(performance.now()-began<2000,'Failure snapshot exceeded bounded collection budget');
  assert.equal(receipt.peers[0].connection,'connecting');assert.equal(receipt.peers[1].connection,'connecting');
  assert.equal(receipt.stats[0].status,'available');assert.equal(receipt.stats[1].status,'timeout');
  finish(new Map());await new Promise(resolve=>setImmediate(resolve));
  assert.equal(receipt.stats[1].status,'timeout','Late stats rewrote the frozen failed receipt');
});

test('exact browser-serialized helper handles getStats refusal without external closure dependencies',async()=>{
  const browserFunction=vm.runInNewContext('('+captureLoopbackFailure.toString()+')',{setTimeout,clearTimeout});
  const source=peer();source.getStats=async()=>{throw new Error(secret);};
  const receipt=await browserFunction({phase:'create-answer',peers:[source]});
  assert.equal(receipt.stats[0].status,'unavailable');assert(!JSON.stringify(receipt).includes(secret));
});

test('actual diagnostic page failure path snapshots both peers before its finally cleanup',async()=>{
  const source=await fs.readFile(new URL('./owned-null-audio-loopback.mjs',import.meta.url),'utf8');
  const match=source.match(/const app=String\.raw`([\s\S]*?)`;\nclass CDP/);
  assert(match,'Read the actual diagnostic page, without importing its browser launcher');
  const app=match[1].replace('${captureLoopbackFailure.toString()}',captureLoopbackFailure.toString());
  const events=[];let failed;
  const node=()=>({connect(){return this;},port:{},frequency:{},gain:{},start(){}});
  const player={muted:true,paused:false,readyState:0,addEventListener(){}};
  class Context {
    state='running';sampleRate=48000;sinkId={type:'none'};currentTime=0;
    audioWorklet={addModule:async()=>{}};
    async resume(){} createChannelMerger(){return node();}createOscillator(){return node();}createGain(){return node();}
    createMediaStreamDestination(){return {stream:{getTracks:()=>[{stop(){events.push('track-stop');}}]}};}
    async close(){events.push('context-close');}
  }
  class Peer {
    connectionState='new';iceConnectionState='new';iceGatheringState='new';signalingState='stable';
    addEventListener(){}addTrack(){}
    async createOffer(){throw new Error(secret);}
    async getStats(){events.push('stats');return new Map();}
    close(){this.connectionState='closed';events.push('peer-close');}
  }
  const done=new Promise(resolve=>{
    vm.runInNewContext(app,{setTimeout,clearTimeout,performance,window:{},
      document:{getElementById:()=>player},AudioContext:Context,AudioWorkletNode:class{constructor(){return node();}},
      RTCPeerConnection:Peer,console:{debug(_tag,json){const value=JSON.parse(json);if(value.kind==='failure'){failed=value.value;events.push('failure');resolve();}}}});
  });
  await done;
  assert.deepEqual(events,['stats','stats','failure','track-stop','peer-close','peer-close','context-close','context-close']);
  assert.equal(failed.snapshot.phase,'create-offer');assert.equal(failed.snapshot.peers.length,2);
  assert(failed.snapshot.peers.every(peer=>peer.connection==='new'));
  assert(!JSON.stringify(failed).includes(secret));
  assert.equal(failed.message,'owned-api-refusal');
});
