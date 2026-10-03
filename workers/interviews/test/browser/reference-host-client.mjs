import assert from 'node:assert/strict';
import { test } from 'node:test';
import { InterviewReferenceHost } from '../../public/host.js';

const settle = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; };
const relayResponse = () => ({ok:true, json:async () => ({ttl:600, iceServers:[
  {urls:'turn:relay.example.test:3478', username:'fixture', credential:'fixture'}
]})});

function fixture() {
  const context = {clock:1e6, nextTimer:0, timers:new Map(), sockets:[], peers:[], streams:[], fetches:[],
    room:crypto.randomUUID(), hostID:crypto.randomUUID(), generation:crypto.randomUUID()};
  class Track {
    constructor(kind) { this.kind = kind; this.stopped = false; }
    stop() { this.stopped = true; }
  }
  class Stream {
    constructor(tracks=[]) { this.tracks = tracks; }
    getTracks() { return this.tracks; }
    addTrack(track) { this.tracks.push(track); }
  }
  class Socket {
    static OPEN = 1;
    constructor(url, protocols) {
      Object.assign(this, {url, protocols, readyState:1, bufferedAmount:0, sent:[]});
      context.sockets.push(this);
    }
    send(data) { this.sent.push(JSON.parse(data)); }
    close() { this.readyState = 3; this.onclose?.({code:1000}); }
    message(data) { this.onmessage?.({data:JSON.stringify(data)}); }
  }
  class Peer {
    constructor(config) {
      Object.assign(this, {config, transceivers:[], tracks:[], candidates:[], configurationChanges:0});
      context.peers.push(this);
    }
    addTransceiver(kind, options) {
      const transceiver={kind,direction:options.direction,mid:null,sender:{
        setStreams() {},replaceTrack:async track=>{transceiver.sender.track=track;this.tracks=this.transceivers.map(value=>value.sender.track).filter(Boolean);}
      }};this.transceivers.push(transceiver);return transceiver;
    }
    createDataChannel(label) {
      this.channel={label,readyState:'connecting',bufferedAmount:0,sent:[],
        send(value){this.sent.push(JSON.parse(value));},
        open(){this.readyState='open';this.onopen?.();},
        message(value){this.onmessage?.({data:JSON.stringify(value)});},
        close(){this.readyState='closed';this.onclose?.();}};return this.channel;
    }
    addTrack(track) { this.tracks.push(track); }
    async createOffer() { return context.offerWait ? await context.offerWait.promise : {type:'offer', sdp:'fixture-sdp'}; }
    async setLocalDescription(description) {
      this.localDescription = description;
      this.transceivers.forEach((value,index)=>value.mid=String(index));
      this.onicecandidate?.({candidate:{toJSON:() => ({candidate:'local', sdpMid:'0'})}});
    }
    async setRemoteDescription(description) {
      if (this.answerWait) await this.answerWait.promise;
      this.remoteDescription = description;
    }
    async addIceCandidate(candidate) {
      this.candidates.push(candidate);
      if (candidate.candidate === 'reject') throw new Error('Fixture rejected candidate');
    }
    setConfiguration(config) { this.config = config; this.configurationChanges++; }
    close() { this.closed = true;this.channel?.close(); }
  }
  const location = {search:`?room=${context.room}`, hash:'#'+'a'.repeat(64), pathname:'/host.html',
    protocol:'https:', host:'interviews.example.test'};
  const history = {replaceState(_state, _unused, url) {
    assert.equal(url, `/host.html?room=${context.room}`);
    location.hash = '';
  }};
  context.fetchImpl = async () => relayResponse();
  context.host = new InterviewReferenceHost({location, history, WebSocket:Socket, RTCPeerConnection:Peer,
    fetch:(url, init) => {context.fetches.push({url, init}); return context.fetchImpl(url, init);},
    mediaDevices:{getUserMedia:async () => {
      const stream = new Stream([new Track('audio'), new Track('video')]);
      context.streams.push(stream); return stream;
    }}, MediaStream:Stream, randomUUID:() => crypto.randomUUID(), now:() => context.clock,
    setTimeout:(fn, delay) => {const id = ++context.nextTimer; context.timers.set(id, {fn, at:context.clock+delay}); return id;},
    clearTimeout:id => context.timers.delete(id)});
  assert.equal(location.hash, '');
  context.connect = () => {
    context.host.connect(); context.socket = context.sockets.at(-1);
    context.generation = crypto.randomUUID();
    context.socket.onopen();
    context.socket.message({type:'welcome', delivery:1, id:context.hostID, role:'host',
      generation:context.generation, expires:context.clock+7200000});
    assert(context.socket.sent.some(data => data.type==='ack' && data.delivery===1));
    return context.socket;
  };
  context.roster = peers => context.socket.message({type:'roster', peers:peers.map(peer => ({
    id:peer.id, role:'guest', name:'Fixture guest', state:peer.state ?? 'backstage'
  })), program:false, recording:false, locked:false});
  context.admit = async (id=crypto.randomUUID()) => {
    const guest = {id, generation:crypto.randomUUID()};
    context.socket.message({type:'admitted', guest:id, guestGeneration:guest.generation, state:'backstage'});
    await settle(); return guest;
  };
  context.signal = (guest, kind, payload, extra={}) => context.socket.message({
    type:'signal', from:guest.id, generation:guest.generation, targetGeneration:context.generation,
    kind, payload:JSON.stringify(payload), ...extra
  });
  context.advance = async ms => {
    const until = context.clock+ms;
    for (;;) {
      const entry = [...context.timers].filter(([, value]) => value.at<=until).sort((a,b) => a[1].at-b[1].at)[0];
      if (!entry) break;
      context.clock = entry[1].at; context.timers.delete(entry[0]); await entry[1].fn(); await settle();
    }
    context.clock = until; await settle();
  };
  context.connect(); return context;
}

test('explicit admission, authoritative state, recv-only media and paced ICE', async () => {
  const f = fixture(); const id = crypto.randomUUID(); f.roster([{id, state:'waiting'}]);
  f.host.stage(id); assert(!f.socket.sent.some(data => data.type==='stage'));
  f.host.admit(id); assert(f.socket.sent.some(data => data.type==='admit'));
  assert.equal(f.host.peers.size, 0, 'A request must not create media before server admission');
  await f.admit(id); f.roster([{id}]); const record = f.host.peers.get(id);
  assert.deepEqual(record.pc.transceivers.map(value=>[value.kind,value.direction]), [['audio','recvonly'], ['video','recvonly'], ['video','recvonly']]);
  assert.deepEqual(f.socket.sent.find(data=>data.kind==='offer') && JSON.parse(f.socket.sent.find(data=>data.kind==='offer').payload).media,{audio:'0',camera:'1',screen:'2'});
  assert.equal(record.pc.tracks.length, 0); assert.equal(f.fetches.length, 1);
  assert(!f.socket.sent.some(data => data.kind==='candidate'));
  await f.advance(30);
  assert(f.socket.sent.findIndex(data => data.kind==='offer') < f.socket.sent.findIndex(data => data.kind==='candidate'));
  f.host.stage(id); assert(f.socket.sent.some(data => data.type==='stage'));
  assert.equal(f.host.members.get(id).state, 'backstage', 'Only server roster changes stage state');
  f.host.setStatus(true, true); f.host.lock(true);
  assert.deepEqual(f.host.flags, {locked:false, program:false, recording:false}, 'Status/lock requests wait for server state');
  f.socket.message({type:'roster', peers:[{id, role:'guest', name:'Fixture guest', state:'onair'}], locked:true, program:true, recording:true});
  assert.deepEqual(f.host.flags, {locked:true, program:true, recording:true});
  f.host.leave(); assert.equal(f.timers.size, 0);
});

test('screen approval is explicit, negotiation scoped and resets on media restart', async()=>{
  const f=fixture(),guest=await f.admit(),record=f.host.peers.get(guest.id);
  assert.equal(record.screenApproved,false);
  f.host.approveScreen(guest.id,true);assert.equal(record.screenApproved,false,'Closed control channels cannot grant sharing');
  record.control.open();assert.deepEqual(record.control.sent.at(-1),{type:'screen-approval',negotiation:record.negotiation,approved:false});
  record.control.message({type:'screen-state',negotiation:record.negotiation,sharing:true});assert.equal(record.screenSharing,false,'A guest cannot approve itself');
  f.host.approveScreen(guest.id,true);assert.equal(record.screenApproved,true);
  record.control.message({type:'screen-state',negotiation:crypto.randomUUID(),sharing:true});assert.equal(record.screenSharing,false);
  record.control.message({type:'screen-state',negotiation:record.negotiation,sharing:true});assert.equal(record.screenSharing,true);
  const camera={kind:'video',stop(){this.stopped=true;}},audio={kind:'audio',stop(){this.stopped=true;}},screen={kind:'video',stop(){this.stopped=true;}};
  for(const [track,mid]of [[camera,'1'],[audio,'0'],[screen,'2']])record.pc.ontrack({track,transceiver:{mid},streams:[]});
  assert.deepEqual(record.stream.getTracks(),[camera,audio]);assert.deepEqual(record.screenStream.getTracks(),[screen]);
  f.host.approveScreen(guest.id,false);assert.equal(record.screenSharing,false);assert(!camera.stopped && !audio.stopped);
  f.host.restartGuest(guest.id);await settle();const next=f.host.peers.get(guest.id);
  assert.equal(next.screenApproved,false);assert(record.control.readyState==='closed');assert(camera.stopped && audio.stopped && screen.stopped);
  record.control.message({type:'screen-state',negotiation:record.negotiation,sharing:true});assert.equal(next.screenSharing,false);
  next.control.open();f.host.approveScreen(guest.id,true);next.control.close();assert.equal(next.screenApproved,false);
  f.host.leave();assert.equal(f.timers.size,0);
});

test('screen control backlog closes only the control channel and keeps camera media',async()=>{
  const f=fixture(),guest=await f.admit(),record=f.host.peers.get(guest.id);record.control.open();
  record.control.bufferedAmount=8193;f.host.approveScreen(guest.id,true);
  assert.equal(record.control.readyState,'closed');assert.equal(record.screenApproved,false);assert(!record.pc.closed);
  f.host.leave();
});

test('matching generations/negotiations, bounded candidates and candidate failure isolation', async () => {
  const f = fixture(); const guest = await f.admit(); const record = f.host.peers.get(guest.id);
  f.signal(guest, 'candidate', {negotiation:crypto.randomUUID(), candidate:{candidate:'stale'}});
  f.signal(guest, 'candidate', {negotiation:record.negotiation, candidate:{candidate:'wrong generation'}}, {generation:crypto.randomUUID()});
  f.signal(guest, 'candidate', {negotiation:record.negotiation, candidate:{candidate:'reject'}});
  for (let index=0; index<140; index++) {
    f.signal(guest, 'candidate', {negotiation:record.negotiation, candidate:{candidate:'accepted', sdpMid:'0'}});
    if (index%20===19) await settle();
  }
  await settle(); assert.equal(record.candidates.length, 128);
  f.signal(guest, 'answer', {negotiation:record.negotiation, description:{type:'answer', sdp:'fixture-answer'}});
  await settle(); assert.equal(record.pc.remoteDescription.type, 'answer');
  assert.equal(record.pc.candidates.length, 128); assert.equal(record.candidates.length, 0);
  const oldNegotiation = record.negotiation; f.host.restartGuest(guest.id); await settle();
  const next = f.host.peers.get(guest.id); assert(record.pc.closed); assert.notEqual(next.negotiation, oldNegotiation);
  f.signal(guest, 'answer', {negotiation:oldNegotiation, description:{type:'answer', sdp:'obsolete'}});
  await settle(); assert(!next.pc.remoteDescription); assert.equal(next.generation, guest.generation);
  f.host.leave();
});

test('32 pending signals per peer acknowledges receipt and leaves another peer healthy', async () => {
  const f = fixture(); const slow = await f.admit(); const healthy = await f.admit();
  const blocked = f.host.peers.get(slow.id), other = f.host.peers.get(healthy.id);
  blocked.pc.answerWait = deferred();
  f.signal(slow, 'answer', {negotiation:blocked.negotiation, description:{type:'answer', sdp:'blocked'}});
  await settle();
  for (let index=0; index<50; index++) f.signal(slow, 'candidate', {
    negotiation:blocked.negotiation, candidate:{candidate:'queued'}
  }, {delivery:index+2});
  assert.equal(blocked.pendingSignals, 32);
  assert.equal(f.socket.sent.filter(data => data.type==='ack').length, 51);
  f.signal(healthy, 'answer', {negotiation:other.negotiation, description:{type:'answer', sdp:'healthy'}});
  await settle(); assert.equal(other.pc.remoteDescription.sdp, 'healthy');
  assert.equal(other.generation, healthy.generation); assert(!other.pc.closed);
  blocked.pc.answerWait.resolve(); await settle(); assert.equal(blocked.pendingSignals, 0);
  assert(blocked.pc.candidates.length<=31); f.host.leave();
});

test('expiry-aware relay refresh, cached rejoin, explicit return and acknowledged end cleanup', async () => {
  const f = fixture(); const guest = await f.admit(); f.roster([guest]);
  await f.host.enableReturn(); await settle(); assert.equal(f.host.peers.get(guest.id).pc.tracks.length, 2);
  f.host.stopReturn(); await settle(); assert(f.streams[0].getTracks().every(track => track.stopped));
  assert.equal(f.host.peers.get(guest.id).pc.tracks.length, 0);
  await f.advance(480000); assert.equal(f.fetches.length, 2);
  assert.equal(f.host.peers.get(guest.id).pc.configurationChanges, 1);
  f.connect(); f.roster([guest]); f.host.admit(guest.id);
  assert(f.socket.sent.some(data => data.type==='admit'), 'A replacement host can explicitly readmit an inherited backstage roster');
  const replacement = await f.admit(); assert.equal(f.fetches.length, 2);
  assert.equal(f.host.peers.get(replacement.id).generation, replacement.generation);
  await f.host.enableReturn(); await settle(); const stream = f.host.localStream;
  f.host.end(); assert(stream.getTracks().every(track => track.stopped)); assert.equal(f.host.valid, false);
  assert.equal(f.host.peers.size, 0); assert(f.socket.sent.some(data => data.type==='end'));
  const countBeforeEnded = f.streams.length; await f.host.enableReturn();
  assert.equal(f.streams.length, countBeforeEnded, 'Waiting for End acknowledgement cannot reopen devices');
  f.socket.message({type:'ended'}); assert.equal(f.host.connected, false); assert.equal(f.timers.size, 0);
  const count = f.sockets.length; f.host.connect(); assert.equal(f.sockets.length, count);
});

for (const action of ['leave', 'end', 'replace']) test(`late TURN response after ${action} cannot publish old offers`, async () => {
  const f = fixture(); const wait = deferred(); f.fetchImpl = async () => wait.promise;
  const guest = await f.admit(); const previous = f.socket; const previousEpochGeneration = f.generation;
  assert.equal(f.fetches.length, 1);
  if (action==='replace') f.connect(); else f.host[action]();
  assert(f.fetches[0].init.signal.aborted);
  wait.resolve(relayResponse()); await settle();
  assert(!previous.sent.some(data => data.kind==='offer'));
  assert.equal(f.host.peers.size, 0); assert.equal(f.peers.length, 0);
  if (action==='replace') {
    f.fetchImpl = async () => relayResponse(); const active = await f.admit(guest.id);
    assert.notEqual(f.generation, previousEpochGeneration); assert.equal(f.fetches.length, 2);
    assert.equal(f.host.peers.get(active.id).generation, active.generation);
    assert(f.socket.sent.some(data => data.kind==='offer'));
  }
  f.host.leave(); assert.equal(f.timers.size, 0);
});

test('late created offer after a new negotiation does not mutate or signal the replaced peer', async () => {
  const f = fixture(); f.offerWait = deferred(); const guest = await f.admit();
  const old = f.host.peers.get(guest.id), firstWait = f.offerWait; f.offerWait = undefined;
  f.host.restartGuest(guest.id); await settle(); const current = f.host.peers.get(guest.id);
  assert(old.pc.closed); assert.equal(current.generation, guest.generation);
  firstWait.resolve({type:'offer', sdp:'obsolete'}); await settle();
  assert(!old.pc.localDescription); assert.equal(f.socket.sent.filter(data => data.kind==='offer').length, 1);
  assert.equal(current.pc.localDescription.sdp, 'fixture-sdp'); f.host.leave();
});

test('relay request timeout aborts fetch; late device permission after leave releases tracks', async () => {
  const f = fixture(); const wait = deferred(); f.fetchImpl = (_url, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener('abort', () => reject(new Error('Aborted')), {once:true});
  });
  await f.admit(); await f.advance(8000); assert(f.fetches[0].init.signal.aborted);
  assert.equal(f.host.peers.values().next().value.pc, undefined);
  f.fetchImpl = async () => relayResponse(); f.host.api.mediaDevices.getUserMedia = () => wait.promise;
  const enabling = f.host.enableReturn(); f.host.leave();
  const tracks = [{stop() {this.stopped=true;}}]; wait.resolve({getTracks:() => tracks}); await enabling;
  assert(tracks.every(track => track.stopped)); assert.equal(f.host.localStream, undefined);
});
