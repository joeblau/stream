import assert from 'node:assert/strict';
import {test} from 'node:test';
import vm from 'node:vm';
import fs from 'node:fs/promises';
import {captureLoopbackFailure} from './owned-loopback-failure-snapshot.mjs';
import {createLoopbackSignalJournal} from './owned-loopback-signal-journal.mjs';

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
    ['pair',{type:'candidate-pair',id:'pair',state:'succeeded',localCandidateId:'local',remoteCandidateId:'remote',address:secret}],
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
  assert.deepEqual(receipt.stats[0].transport,[{dtlsState:'unknown',iceState:'unknown',iceRole:'unknown',dtlsRole:'unknown',selectedCandidatePairReference:true,selectedPairResolved:true,state:'succeeded',local:'host',remote:'relay'}]);
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
  assert.equal(receipt.stats[0].inbound.length,2);assert.equal(receipt.stats[0].rowsInspected,256);
  assert.equal(receipt.stats[0].rowsTruncated,true);assert.equal(receipt.stats[0].countsAreLowerBounds,true);assert.equal(receipt.contexts.length,2);
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
  const app=match[1].replace('${captureLoopbackFailure.toString()}',captureLoopbackFailure.toString())
    .replace('${createLoopbackSignalJournal.toString()}',createLoopbackSignalJournal.toString());
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


test('unselected transport, failed checks, DTLS pending, unresolved selection and absent rows stay distinct',async()=>{
  const reports=[new Map(),new Map([
    ['transport',{type:'transport',dtlsState:'new',iceState:'checking',iceRole:'controlling',dtlsRole:'unknown',bytesSent:0}],
    ['pair',{type:'candidate-pair',id:'pair',state:'failed',nominated:false,requestsSent:5,responsesReceived:0,
      localCandidateId:'local',remoteCandidateId:'remote'}],
    ['local',{type:'local-candidate',candidateType:'host',protocol:'udp',address:secret}],
    ['remote',{type:'remote-candidate',candidateType:'relay',protocol:'udp',address:secret}]
  ]),new Map([
    ['transport',{type:'transport',dtlsState:'connecting',iceState:'connected',iceRole:'controlled',dtlsRole:'server',selectedCandidatePairId:secret}]
  ])];
  const empty=(await captureLoopbackFailure({peers:[peer(reports[0])]})).stats[0];
  const checks=(await captureLoopbackFailure({peers:[peer(reports[1])]})).stats[0];
  const dtls=(await captureLoopbackFailure({peers:[peer(reports[2])]})).stats[0];
  assert.equal(empty.transportCount,0);assert.deepEqual(empty.transport,[]);
  assert.equal(checks.transportCount,1);assert.equal(checks.transport[0].selectedCandidatePairReference,false);
  assert.equal(checks.transport[0].bytesSent,0);assert.equal(checks.transport[0].packetsSent,undefined);
  assert.equal(checks.pairs[0].state,'failed');assert.equal(checks.pairs[0].responsesReceived,0);
  assert.equal(checks.candidates.local.types.host,1);assert.equal(checks.candidates.remote.types.relay,1);
  assert.equal(dtls.transport[0].dtlsState,'connecting');assert.equal(dtls.transport[0].iceState,'connected');
  assert.equal(dtls.transport[0].selectedCandidatePairReference,true);assert.equal(dtls.transport[0].selectedPairResolved,false);
  assert(!JSON.stringify([checks,dtls]).includes(secret));
});

test('pair and transport retention caps preserve observed counts with explicit truncation',async()=>{
  const rows=new Map(Array.from({length:12},(_,i)=>['pair'+i,{type:'candidate-pair',id:'pair'+i,state:'in-progress',
    requestsSent:i,localCandidateId:secret,remoteCandidateId:secret}]));
  for(let i=0;i<3;i++)rows.set('transport'+i,{type:'transport',selectedCandidatePairId:'pair0',dtlsState:'new'});
  const stats=(await captureLoopbackFailure({peers:[peer(rows)]})).stats[0];
  assert.equal(stats.pairCount,12);assert.equal(stats.pairs.length,8);assert.equal(stats.pairRowsTruncated,true);
  assert.equal(stats.transportCount,3);assert.equal(stats.transport.length,2);assert.equal(stats.transportRowsTruncated,true);
  assert.equal(stats.rowsTruncated,false);assert.equal(stats.countsAreLowerBounds,false);
  assert.equal(stats.pairs[0].referencedAsSelected,true);assert.equal(stats.pairs[0].nominated,undefined);
  assert(!JSON.stringify(stats).includes(secret));
});

test('signaling allowlist is copied before getStats and ignores arbitrary input fields',async()=>{
  let release;const source=peer();source.getStats=()=>new Promise(resolve=>{release=resolve;});
  const signaling={generation:1,active:true,sequence:3,private:secret,counts:Array(20).fill({side:'sender',operation:'add-ice-candidate',inFlight:1,private:secret}),
    events:Array(100).fill({generation:1,sequence:3,side:secret,kind:'start',phase:secret,error:secret,private:secret})};
  const pending=captureLoopbackFailure({peers:[source],signaling});
  signaling.counts[0].inFlight=0;signaling.events[0].kind='complete';release(new Map());
  const receipt=await pending;
  assert.equal(receipt.signaling.counts.length,10);assert.equal(receipt.signaling.events.length,64);
  assert.equal(receipt.signaling.inputTruncated,true);assert.equal(receipt.signaling.counts[0].inFlight,1);
  assert.equal(receipt.signaling.events[0].kind,'start');assert(!JSON.stringify(receipt).includes(secret));
});


test('selected reference to a non-pair row is unresolved and does not invent pair evidence',async()=>{
  const report=new Map([['transport',{type:'transport',selectedCandidatePairId:'other'}],['other',{type:'codec',state:'succeeded'}]]);
  const stats=(await captureLoopbackFailure({peers:[peer(report)]})).stats[0];
  assert.equal(stats.transport[0].selectedCandidatePairReference,true);assert.equal(stats.transport[0].selectedPairResolved,false);
  assert.equal(stats.transport[0].state,undefined);assert.equal(stats.pairCount,0);
});

test('actual serialized page awaits queued candidates but not held trickle promises on either peer',async()=>{
  const source=await fs.readFile(new URL('./owned-null-audio-loopback.mjs',import.meta.url),'utf8');
  const match=source.match(/const app=String\.raw`([\s\S]*?)`;\nclass CDP/);
  const app=match[1].replace('${captureLoopbackFailure.toString()}',captureLoopbackFailure.toString())
    .replace('${createLoopbackSignalJournal.toString()}',createLoopbackSignalJournal.toString());
  const calls=[],peers=[],held=[],queued=[],stages=[];let failed,stopAtWait=true,receiverQueued,senderQueued;
  const firstQueued=new Promise(resolve=>{receiverQueued=resolve;}),secondQueued=new Promise(resolve=>{senderQueued=resolve;});
  const node=()=>({connect(){return this;},port:{},frequency:{},gain:{},start(){}});
  const player={muted:true,paused:false,readyState:0,addEventListener(){}};
  class Context {
    state='running';sampleRate=48000;sinkId={type:'none'};currentTime=0;audioWorklet={addModule:async()=>{}};
    async resume(){}createChannelMerger(){return node();}createOscillator(){return node();}createGain(){return node();}
    createMediaStreamDestination(){return {stream:{getTracks:()=>[{stop(){calls.push('track-stop');}}]}};}
    async close(){calls.push('context-close');}
  }
  class Peer {
    constructor(){this.side=peers.length?'receiver':'sender';peers.push(this);}
    iceConnectionState='new';iceGatheringState='complete';signalingState='stable';
    get connectionState(){if(stopAtWait){stopAtWait=false;throw new Error(secret);}return 'new';}
    addEventListener(){}addTrack(){}
    async createOffer(){calls.push('sender-offer');return {type:'offer',sdp:secret};}
    async createAnswer(){calls.push('receiver-answer');return {type:'answer',sdp:secret};}
    async setLocalDescription(description){
      calls.push(this.side+'-local');this.localDescription=description;
      this.onicecandidate({candidate:{queued:true,private:secret}});this.onicecandidate({candidate:null});
    }
    async setRemoteDescription(description){
      calls.push(this.side+'-remote');this.remoteDescription=description;
      // The other peer's direct trickle call is held; the page must continue
      // to its existing awaited pending-candidate loop without awaiting this.
      peers[this.side==='sender'?1:0].onicecandidate({candidate:{queued:false,private:secret}});
    }
    addIceCandidate(candidate){
      calls.push(this.side+(candidate.queued?'-queued':'-direct'));
      if(candidate.queued)return new Promise(resolve=>{queued.push(resolve);(this.side==='receiver'?receiverQueued:senderQueued)();});
      return new Promise(resolve=>held.push(resolve));
    }
    async getStats(){calls.push(this.side+'-stats');return new Map();}
    close(){calls.push(this.side+'-close');}
  }
  const done=new Promise(resolve=>{
    vm.runInNewContext(app,{setTimeout,clearTimeout,performance,window:{},document:{getElementById:()=>player},
      AudioContext:Context,AudioWorkletNode:class{constructor(){return node();}},RTCPeerConnection:Peer,
      console:{debug(_tag,json){const event=JSON.parse(json);if(event.kind==='stage')stages.push(event.value);if(event.kind==='failure'){failed=event.value;resolve();}}}});
  });
  await firstQueued;await new Promise(resolve=>setImmediate(resolve));
  assert(!calls.includes('receiver-answer'),'Receiver queue was not awaited');assert.equal(held.length,1);
  queued[0]();await secondQueued;await new Promise(resolve=>setImmediate(resolve));
  assert(!stages.includes('connection-wait'),'Sender queue was not awaited');assert.equal(held.length,2);
  queued[1]();await done;
  assert.deepEqual(calls.slice(0,9),['sender-offer','sender-local','receiver-remote','receiver-direct','receiver-queued',
    'receiver-answer','receiver-local','sender-remote','sender-direct']);
  assert.equal(calls[9],'sender-queued');assert.equal(held.length,2);
  assert.equal(failed.snapshot.phase,'connection-wait');
  const journal=failed.snapshot.signaling;
  assert.equal(journal.active,true);assert.equal(journal.generation,1);
  for(const side of ['sender','receiver']){
    const row=journal.counts.find(row=>row.side===side&&row.operation==='add-ice-candidate');
    assert.equal(row.started,2);assert.equal(row.completed,1);assert.equal(row.inFlight,1);
    assert(journal.events.some(row=>row.side===side&&row.kind==='candidate-queued'));
    assert(journal.events.some(row=>row.side===side&&row.kind==='candidate-end'));
  }
  assert(calls.indexOf('sender-stats')<calls.indexOf('sender-close'));
  const frozen=JSON.stringify(failed);held.forEach(resolve=>resolve());await new Promise(resolve=>setImmediate(resolve));
  assert.equal(JSON.stringify(failed),frozen);assert(!frozen.includes(secret));
});
