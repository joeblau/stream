// Deterministic capture lifecycle tests. These do not qualify actual browsers,
// native receivers, relay reachability, or production audio/video quality.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {test} from 'node:test';

const source = await readFile(new URL('../../public/guest.js', import.meta.url), 'utf8');
const deferred = () => {let resolve; const promise = new Promise(value => {resolve=value;}); return {promise, resolve};};
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const elements = new Map(), captures = [], contexts = [];
  class Track {
    constructor(kind) {this.kind=kind; this.enabled=true; this.readyState='live'; this.listeners={};}
    stop() {this.readyState='ended';}
    getSettings() {return {deviceId:`fixture-${this.kind}`};}
    addEventListener(type, callback) {this.listeners[type]=callback;}
  }
  class Stream {
    constructor(tracks=[]) {this.tracks=[...tracks];}
    getTracks() {return this.tracks;}
    getAudioTracks() {return this.tracks.filter(track=>track.kind==='audio');}
    getVideoTracks() {return this.tracks.filter(track=>track.kind==='video');}
  }
  class Audio {
    constructor() {this.closed=false;contexts.push(this);}
    resume() {return Promise.resolve();}
    close() {this.closed=true;return Promise.resolve();}
    createAnalyser() {return {fftSize:512, disconnect(){}, getFloatTimeDomainData(){}};}
    createMediaStreamSource() {return {connect(){}, disconnect(){}};}
  }
  const element = id => {
    if (!elements.has(id)) elements.set(id, {value:'', disabled:false, textContent:'',
      replaceChildren(){}, append(){}, get length(){return 0;}});
    return elements.get(id);
  };
  const sandbox = {URLSearchParams, TextEncoder, AbortSignal, MediaStream:Stream,
    location:{search:'?room=00000000-0000-4000-8000-000000000000', hash:'#'+'a'.repeat(64), pathname:'/guest.html'},
    history:{replaceState(){}}, document:{getElementById:element, createElement:()=>({})},
    navigator:{mediaDevices:{getUserMedia:constraints=>{
      const capture=deferred(); captures.push({...capture,constraints}); return capture.promise;
    }, enumerateDevices:async()=>[], addEventListener(){}}},
    AudioContext:Audio, requestAnimationFrame:()=>1, cancelAnimationFrame(){},
    setTimeout, clearTimeout, window:{addEventListener(){}}, WebSocket:{OPEN:1}};
  vm.createContext(sandbox);
  vm.runInContext(source+`;globalThis.guest={prepare,switchDevice,leave,resetPeer,acceptSignal,
    setAdmission:()=>{admitted=true;generation="guest-generation";host="host-id";hostGeneration="host-generation";},
    setPeer:value=>{pc=value;},
    snapshot:()=>({local,senders:mediaSenders,left,secret}),setSenders:value=>{mediaSenders=value;},
    setSocket:value=>{socket=value;}};`,sandbox);
  const f={...sandbox.guest,element,captures,contexts,sandbox,
    stream:(...kinds)=>new Stream(kinds.map(kind=>new Track(kind)))};
  f.prepareDevices=async()=>{
    const pending=f.prepare(),stream=f.stream('audio','video');captures.at(-1).resolve(stream);await pending;return stream;
  };
  f.sender=track=>({track,replaceTrack:async function(next){this.track=next;}});
  return f;
}

test('a failed second sender replacement rolls back the first and stops fresh capture',async()=>{
  const f=fixture(),old=await f.prepareDevices();
  const audio=f.sender(old.getAudioTracks()[0]),camera=f.sender(old.getVideoTracks()[0]);
  camera.replaceTrack=async()=>{throw new Error('Needs renegotiation');};
  f.setSenders({audio,camera});
  const pending=f.prepare(),fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(f.snapshot().local,old);assert.equal(audio.track,old.getAudioTracks()[0]);
  assert(old.getTracks().every(track=>track.readyState==='live'));
  assert(fresh.getTracks().every(track=>track.readyState==='ended'));
  assert.match(f.element('status').textContent,/previous devices/);
});

test('leave while replaceTrack is pending stops capture without reviving preview or audio',async()=>{
  const f=fixture(),old=await f.prepareDevices(),wait=deferred();
  const audio=f.sender(old.getAudioTracks()[0]);
  audio.replaceTrack=async track=>{await wait.promise;audio.track=track;};f.setSenders({audio});
  const pending=f.prepare(),fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await settle();
  await f.leave();
  assert(fresh.getTracks().every(track=>track.readyState==='ended'),'Leave stops in-flight devices before replacement settles');
  wait.resolve();await pending;
  assert.equal(f.snapshot().local,undefined);assert.equal(f.snapshot().secret,'');
  assert.equal(f.element('preview').srcObject,null);assert.equal(f.element('prepare').disabled,true);
  assert([...old.getTracks(),...fresh.getTracks()].every(track=>track.readyState==='ended'));
  assert(f.contexts.every(context=>context.closed));
});

test('a late permission response after leave is immediately stopped',async()=>{
  const f=fixture(),pending=f.prepare(),fresh=f.stream('audio','video');
  await f.leave();f.captures[0].resolve(fresh);await pending;
  assert(fresh.getTracks().every(track=>track.readyState==='ended'));
  assert.equal(f.snapshot().local,undefined);
});

test('overlapping device checks publish only the newest capture',async()=>{
  const f=fixture(),first=f.prepare(),second=f.prepare();
  const stale=f.stream('audio','video'),current=f.stream('audio','video');
  f.captures[1].resolve(current);await second;f.captures[0].resolve(stale);await first;
  assert.equal(f.snapshot().local,current);assert(stale.getTracks().every(track=>track.readyState==='ended'));
  assert(current.getTracks().every(track=>track.readyState==='live'));
});

test('failed device switching retains the old stream and stops the unused track',async()=>{
  const f=fixture(),old=await f.prepareDevices(),camera=f.sender(old.getVideoTracks()[0]);
  camera.replaceTrack=async()=>{throw new Error('Unavailable');};f.setSenders({camera});
  const pending=f.switchDevice('video','new-camera'),fresh=f.stream('video');f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(f.snapshot().local,old);assert.equal(fresh.getTracks()[0].readyState,'ended');
  assert(old.getTracks().every(track=>track.readyState==='live'));
});

test('switching one device preserves the other track and mute controls',async()=>{
  const f=fixture(),old=await f.prepareDevices();
  f.element('hide').onclick();f.element('mute').onclick();
  const pending=f.switchDevice('video','new-camera'),fresh=f.stream('video');f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(f.snapshot().local.getAudioTracks()[0],old.getAudioTracks()[0]);
  assert.equal(old.getVideoTracks()[0].readyState,'ended');
  assert.equal(fresh.getVideoTracks()[0].enabled,false);assert.equal(old.getAudioTracks()[0].enabled,false);
});

test('peer restart cancels capture installation and leaves device check available',async()=>{
  const f=fixture(),old=await f.prepareDevices(),pending=f.prepare();f.resetPeer();
  const fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(f.snapshot().local,old);assert.equal(f.element('prepare').disabled,false);
  assert(fresh.getTracks().every(track=>track.readyState==='ended'));
});

test('device recovery does not enable Join on an existing signaling connection',async()=>{
  const f=fixture();f.setSocket({readyState:1});await f.prepareDevices();assert.equal(f.element('join').disabled,true);
});

test('mute and camera-off during held replacement immediately protect in-flight tracks',async()=>{
  const f=fixture(),old=await f.prepareDevices(),wait=deferred(),audio=f.sender(old.getAudioTracks()[0]);
  audio.replaceTrack=async track=>{audio.track=track;await wait.promise;};f.setSenders({audio});
  const pending=f.prepare(),fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await settle();
  f.element('mute').onclick();f.element('hide').onclick();
  assert.equal(audio.track.enabled,false,'mute must apply before replacement promise resolves');
  wait.resolve();await pending;
  assert(f.snapshot().local.getTracks().every(track=>track.enabled===false));
});

test('a rejected rollback closes the damaged peer and requests explicit readmission',async()=>{
  const f=fixture(),old=await f.prepareDevices(),audio=f.sender(old.getAudioTracks()[0]),camera=f.sender(old.getVideoTracks()[0]);
  const peer={closed:false,close(){this.closed=true;}};f.setPeer(peer);
  let calls=0;audio.replaceTrack=async track=>{if(++calls===2)throw new Error('Rollback failed');audio.track=track;};
  camera.replaceTrack=async()=>{throw new Error('Camera failed');};f.setSenders({audio,camera});
  const pending=f.prepare(),fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(Object.keys(f.snapshot().senders).length,0);assert.equal(peer.closed,true);
  assert.match(f.element('status').textContent,/could not restore host media.*Reconnect/);
  assert(fresh.getTracks().every(track=>track.readyState==='ended'));
  assert(old.getTracks().every(track=>track.readyState==='live'));
});


test('initial negotiation cannot reinstall stopped devices after a concurrent device check',async()=>{
  const f=fixture(),old=await f.prepareDevices(),wait=deferred();
  let peer;
  f.sandbox.fetch=async()=>({ok:true,json:async()=>({iceServers:[]})});
  f.sandbox.RTCPeerConnection=class {
    constructor() {
      peer=this;
      this.transceivers=['audio','video','video'].map((kind,index)=>({mid:String(index),receiver:{track:{kind}},sender:f.sender(null)}));
      for(const value of this.transceivers)value.sender.setStreams=()=>{};
      const sender=this.transceivers[0].sender;
      let calls=0;sender.replaceTrack=async track=>{if(++calls===1)await wait.promise;sender.track=track;};
    }
    getTransceivers(){return this.transceivers;}
    async setRemoteDescription(value){this.remoteDescription=value;}
    async createAnswer(){return {type:'answer',sdp:'fixture'};}
    async setLocalDescription(value){this.localDescription=value;}
    close(){this.closed=true;}
  };
  f.setAdmission();
  const negotiate=f.acceptSignal({targetGeneration:'guest-generation',from:'host-id',generation:'host-generation',kind:'offer',
    payload:JSON.stringify({negotiation:'00000000-0000-4000-8000-000000000001',description:{type:'offer',sdp:'fixture'},media:{audio:'0',camera:'1',screen:'2'}})},0);
  await settle();
  const change=f.prepare(),fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await settle();
  assert(old.getTracks().every(track=>track.readyState==='live'),'device commit must wait for initial sender writes');
  wait.resolve();await negotiate;await change;
  assert.equal(peer.transceivers[0].sender.track,fresh.getAudioTracks()[0]);
  assert.equal(peer.transceivers[1].sender.track,fresh.getVideoTracks()[0]);
  assert(old.getTracks().every(track=>track.readyState==='ended'));
  await f.leave();
});
