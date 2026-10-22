// Deterministic capture lifecycle tests. These do not qualify actual browsers,
// native receivers, relay reachability, or production audio/video quality.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {test} from 'node:test';
import {GuestPublicChatView} from '../../public/public-chat.js';


const source = await readFile(process.env.GUEST_DEVICE_CLIENT_SOURCE ?? new URL('../../public/guest.js', import.meta.url), 'utf8');
// vm.Script cannot parse module imports. Inject the unchanged actual module
// export, retaining its production reset/lifecycle behavior in device cases.
const publicChatImport = "import {GuestPublicChatView} from './public-chat.js';";
assert(source.includes(publicChatImport), 'Guest public-chat module boundary changed');
const executableSource = source.replace(publicChatImport, '');
const deferred = () => {let resolve,reject; const promise = new Promise((yes,no) => {resolve=yes;reject=no;}); return {promise,resolve,reject};};
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const elements = new Map(), captures = [], contexts = [];
  class Track {
    constructor(kind,deviceId=`fixture-${kind}`) {this.kind=kind;this.deviceId=deviceId; this.enabled=true; this.readyState='live'; this.listeners={};}
    stop() {this.readyState='ended';}
    endExternally() {this.readyState='ended';this.listeners.ended?.();}
    getSettings() {return {deviceId:this.deviceId};}
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
    if (!elements.has(id)) elements.set(id, {value:'', disabled:false, textContent:'', dataset:{},
      children:[],replaceChildren(...values){this.children=[...values];},append(...values){this.children.push(...values);},get length(){return this.children.length;}});
    return elements.get(id);
  };
  const sandbox = {URLSearchParams, TextEncoder, AbortSignal, MediaStream:Stream, GuestPublicChatView, performance, crypto,
    location:{search:'?room=00000000-0000-4000-8000-000000000000', hash:'#'+'a'.repeat(64), pathname:'/guest.html'},
    history:{replaceState(){}}, document:{getElementById:element, createElement:()=>({})},
    navigator:{mediaDevices:{getUserMedia:constraints=>{
      const capture=deferred(); captures.push({...capture,constraints}); return capture.promise;
    }, enumerateDevices:async()=>[], addEventListener(){}}},
    AudioContext:Audio, requestAnimationFrame:()=>1, cancelAnimationFrame(){},
    setTimeout:(callback,ms)=>{const timer=setTimeout(callback,ms);timer.unref();return timer;}, clearTimeout,
    setInterval:(callback,ms)=>{const timer=setInterval(callback,ms);timer.unref();return timer;}, clearInterval, window:{addEventListener(){}}, WebSocket:{OPEN:1}};
  vm.createContext(sandbox);
  vm.runInContext(executableSource+`;globalThis.guest={prepare,switchDevice,enumerate,join,leave,resetPeer,acceptSignal,
    setAdmission:()=>{admitted=true;generation="guest-generation";host="host-id";hostGeneration="host-generation";},
    setPeer:value=>{pc=value;},
    snapshot:()=>({local,senders:mediaSenders,left,secret}),setSenders:value=>{mediaSenders=value;},
    setSocket:value=>{socket=value;}};`,sandbox);
  const f={...sandbox.guest,element,captures,contexts,sandbox,
    stream:(...kinds)=>new Stream(kinds.map(kind=>new Track(kind))),
    streamWithDevices:devices=>new Stream(Object.entries(devices).map(([kind,id])=>new Track(kind,id)))};
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
    async createAnswer(){return {type:'answer',sdp:'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=rtpmap:111 opus/48000/2\r\n'};}
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


test('permission loss blocks new Join while preserving the healthy device and invite',async()=>{
  const f=fixture(),old=await f.prepareDevices(),audio=old.getAudioTracks()[0],camera=old.getVideoTracks()[0];
  camera.endExternally();
  assert.equal(f.element('join').disabled,true,'An ended camera must invalidate prepared-device readiness');
  assert.doesNotThrow(()=>f.join(),'Join with ended devices must stop before creating a signaling socket');
  assert.equal(audio.readyState,'live');assert.equal(f.snapshot().local,old);
  assert.equal(f.snapshot().secret,'a'.repeat(64));
  assert.match(f.element('status').textContent,/check devices again.*invite/);
});

test('permission recovery by one device switch preserves the healthy muted microphone and same invite',async()=>{
  const f=fixture(),old=await f.prepareDevices(),audio=old.getAudioTracks()[0];
  f.element('mute').onclick();old.getVideoTracks()[0].endExternally();
  assert.equal(f.element('join').disabled,true);
  const pending=f.switchDevice('video','restored-camera'),fresh=f.stream('video');
  f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(f.element('join').disabled,false,'Fresh live devices restore Join without a new invite');
  assert.equal(f.snapshot().local.getAudioTracks()[0],audio);assert.equal(audio.enabled,false);
  assert.equal(audio.readyState,'live');assert.equal(f.snapshot().secret,'a'.repeat(64));
  assert.equal(fresh.getVideoTracks()[0].readyState,'live');
});

test('an offer cannot attach ended prepared devices or retire an existing healthy peer',async()=>{
  const f=fixture(),old=await f.prepareDevices(),existing={closed:false,close(){this.closed=true;}};
  f.setAdmission();f.setPeer(existing);old.getVideoTracks()[0].endExternally();
  let constructed=0;
  f.sandbox.RTCPeerConnection=class{constructor(){constructed++;throw new Error('Must not create a peer for ended capture');}};
  f.sandbox.fetch=async()=>{throw new Error('Must not request relay credentials for ended capture');};
  await assert.rejects(f.acceptSignal({targetGeneration:'guest-generation',from:'host-id',generation:'host-generation',kind:'offer',
    payload:JSON.stringify({negotiation:'00000000-0000-4000-8000-000000000001',description:{type:'offer',sdp:'fixture'},media:{audio:'0',camera:'1',screen:'2'}})},0),/Restore camera and microphone/);
  assert.equal(constructed,0);assert.equal(existing.closed,false);
  assert.equal(old.getAudioTracks()[0].readyState,'live');assert.equal(f.snapshot().secret,'a'.repeat(64));
});

test('device permission ending during held replacement rolls back before publishing the new capture',async()=>{
  const f=fixture(),old=await f.prepareDevices(),wait=deferred(),audio=f.sender(old.getAudioTracks()[0]);
  audio.replaceTrack=async track=>{audio.track=track;if(track!==old.getAudioTracks()[0])await wait.promise;};
  f.setSenders({audio});
  const pending=f.prepare(),fresh=f.stream('audio','video');f.captures.at(-1).resolve(fresh);await settle();
  fresh.getAudioTracks()[0].endExternally();wait.resolve();await pending;
  assert.equal(f.snapshot().local,old,'Ended permission result must not become the ready capture');
  assert.equal(audio.track,old.getAudioTracks()[0]);assert(old.getTracks().every(track=>track.readyState==='live'));
  assert(fresh.getTracks().every(track=>track.readyState==='ended'));
});

test('an already-ended permission result is never presented as prepared or joinable',async()=>{
  const f=fixture(),pending=f.prepare(),fresh=f.stream('audio','video');
  fresh.getVideoTracks()[0].endExternally();f.captures.at(-1).resolve(fresh);await pending;
  assert.equal(f.snapshot().local,undefined);assert.equal(f.element('join').disabled,true);
  assert(fresh.getTracks().every(track=>track.readyState==='ended'));
  assert.match(f.element('status').textContent,/Restore camera and microphone/);
});

test('signaling disconnect cannot re-enable Join or Reconnect with an ended microphone',async()=>{
  const f=fixture(),old=await f.prepareDevices(),sockets=[];
  f.sandbox.location.protocol='https:';f.sandbox.location.host='owned.invalid';
  f.sandbox.WebSocket=class {
    static OPEN=1;
    constructor(){this.readyState=0;sockets.push(this);}
    send(){}
    close(){this.readyState=3;}
  };
  f.join();const socket=sockets[0];socket.readyState=1;socket.onopen();
  old.getAudioTracks()[0].endExternally();socket.readyState=3;socket.onclose({code:1006});
  assert.equal(f.element('join').disabled,true,'Socket closure cannot turn an ended capture into a prepared one');
  f.element('rejoin').onclick();assert.equal(sockets.length,1,'Reconnect must check the same live-device readiness');
  assert.equal(old.getVideoTracks()[0].readyState,'live');assert.equal(f.snapshot().secret,'a'.repeat(64));
  assert.match(f.element('status').textContent,/check devices again.*invite/);
});


// Standards-valid getUserMedia selection: an exact ID either resolves that
// device or refuses. Without an exact ID the UA may choose a different default.
function finishDeviceCapture(f, capture, {unavailable=[],defaultPrefix='default'}={}) {
  const selected={};
  for(const kind of ['audio','video'])if(capture.constraints[kind]) {
    const exact=capture.constraints[kind].deviceId?.exact;
    if(unavailable.includes(exact)) {
      capture.reject(Object.assign(new Error('Controlled missing exact device'),{name:'OverconstrainedError'}));return;
    }
    selected[kind]=exact??`${defaultPrefix}-${kind}`;
  }
  const stream=f.streamWithDevices(selected);capture.resolve(stream);return stream;
}
async function chooseDevice(f, kind, id) {
  f.element(kind==='video'?'camera':'microphone').value=id;
  const pending=f.switchDevice(kind,id),fresh=finishDeviceCapture(f,f.captures.at(-1));await pending;return fresh;
}
async function prepareDefaultDevices(f) {
  const pending=f.prepare(),stream=finishDeviceCapture(f,f.captures.at(-1));await pending;return stream;
}

test('rechecking devices retains explicitly selected camera and microphone instead of UA defaults',async()=>{
  const f=fixture();await prepareDefaultDevices(f);
  await chooseDevice(f,'video','usb-camera');await chooseDevice(f,'audio','usb-microphone');
  const previous=f.snapshot().local,peer={closed:false,close(){this.closed=true;}};
  f.setPeer(peer);f.setAdmission();f.setSocket({readyState:1});f.setSenders({camera:f.sender(previous.getVideoTracks()[0]),audio:f.sender(previous.getAudioTracks()[0])});
  f.element('mute').onclick();
  const pending=f.prepare(),fresh=finishDeviceCapture(f,f.captures.at(-1));await pending;
  assert.equal(f.snapshot().local.getVideoTracks()[0].getSettings().deviceId,'usb-camera');
  assert.equal(f.snapshot().local.getAudioTracks()[0].getSettings().deviceId,'usb-microphone');
  assert.equal(fresh.getAudioTracks()[0].enabled,false);assert.equal(peer.closed,false);
  assert.equal(f.element('camera').value,'usb-camera');assert.equal(f.element('microphone').value,'usb-microphone');
  assert.equal(f.snapshot().secret,'a'.repeat(64));
});

test('a missing exact device refuses default fallback and deliberate replacement recovers the same invite',async()=>{
  const f=fixture();await prepareDefaultDevices(f);await chooseDevice(f,'video','usb-camera');
  const old=f.snapshot().local,microphone=old.getAudioTracks()[0],peer={closed:false,close(){this.closed=true;}};
  f.setPeer(peer);f.setAdmission();f.setSocket({readyState:1});f.setSenders({camera:f.sender(old.getVideoTracks()[0]),audio:f.sender(microphone)});
  old.getVideoTracks()[0].endExternally();
  const count=f.captures.length,pending=f.prepare();
  finishDeviceCapture(f,f.captures.at(-1),{unavailable:['usb-camera']});await pending;
  assert.equal(f.captures.length,count+1,'A missing selected device must not trigger a second unconstrained capture');
  assert.equal(f.snapshot().local,old);assert.equal(microphone.readyState,'live');assert.equal(peer.closed,false);
  assert.match(f.element('status').textContent,/selected device is unavailable/i);assert.equal(f.snapshot().secret,'a'.repeat(64));
  await chooseDevice(f,'video','replacement-camera');
  assert.equal(f.snapshot().local.getAudioTracks()[0],microphone);assert.equal(f.element('join').disabled,true,'Existing signaling/host ownership must stay independent of device recovery');
  const recheck=f.prepare();finishDeviceCapture(f,f.captures.at(-1));await recheck;
  assert.equal(f.snapshot().local.getVideoTracks()[0].getSettings().deviceId,'replacement-camera');
  assert.equal(peer.closed,false);assert.equal(f.snapshot().secret,'a'.repeat(64));
});

test('permission refusal preserves committed choices and healthy tracks for the next explicit recheck',async()=>{
  const f=fixture();await prepareDefaultDevices(f);await chooseDevice(f,'video','private-camera');
  const old=f.snapshot().local,pending=f.prepare();
  f.captures.at(-1).reject(Object.assign(new Error('Controlled revoked permission'),{name:'NotAllowedError'}));await pending;
  assert.equal(f.snapshot().local,old);assert(old.getTracks().every(track=>track.readyState==='live'));
  assert.match(f.element('status').textContent,/permission was denied/);
  const retry=f.prepare();finishDeviceCapture(f,f.captures.at(-1));await retry;
  assert.equal(f.snapshot().local.getVideoTracks()[0].getSettings().deviceId,'private-camera');
  assert.equal(f.snapshot().secret,'a'.repeat(64));
});

test('a failed sender replacement does not commit the requested device choice or selector label',async()=>{
  const f=fixture();await prepareDefaultDevices(f);await chooseDevice(f,'video','committed-camera');
  const old=f.snapshot().local,sender=f.sender(old.getVideoTracks()[0]);
  sender.replaceTrack=async function(track){if(track?.getSettings().deviceId==='rejected-camera')throw new Error('Controlled renegotiation required');this.track=track;};
  f.setSenders({camera:sender});
  const failed=await chooseDevice(f,'video','rejected-camera');
  assert(failed.getTracks().every(track=>track.readyState==='ended'));assert.equal(f.snapshot().local,old);
  assert.equal(f.element('camera').value,'committed-camera','A failed deliberate replacement must show its retained source');
  const pending=f.prepare();finishDeviceCapture(f,f.captures.at(-1));await pending;
  assert.equal(f.snapshot().local.getVideoTracks()[0].getSettings().deviceId,'committed-camera');
});

test('a late superseded selection cannot overwrite the latest committed choice used by recheck',async()=>{
  const f=fixture();await prepareDefaultDevices(f);
  const late=f.switchDevice('video','late-camera'),lateCapture=f.captures.at(-1);
  const current=f.switchDevice('video','current-camera');finishDeviceCapture(f,f.captures.at(-1));await current;
  const stale=finishDeviceCapture(f,lateCapture);await late;
  assert(stale.getTracks().every(track=>track.readyState==='ended'));
  const pending=f.prepare();finishDeviceCapture(f,f.captures.at(-1));await pending;
  assert.equal(f.snapshot().local.getVideoTracks()[0].getSettings().deviceId,'current-camera');
  assert.equal(f.snapshot().secret,'a'.repeat(64));
});

test('device enumeration retains an unavailable committed choice without selecting another source',async()=>{
  const f=fixture();await prepareDefaultDevices(f);await chooseDevice(f,'video','unplugged-camera');
  f.sandbox.navigator.mediaDevices.enumerateDevices=async()=>[
    {kind:'videoinput',deviceId:'other-camera',label:'Other camera'},
    {kind:'audioinput',deviceId:'default-audio',label:'Microphone'}
  ];
  await f.enumerate();
  assert(f.element('camera').children.some(option=>option.value==='unplugged-camera' && option.disabled),
    'A missing committed choice must stay visible instead of the first listed camera becoming selected');
  assert.equal(f.element('camera').value,'unplugged-camera');
  const pending=f.prepare();finishDeviceCapture(f,f.captures.at(-1),{unavailable:['unplugged-camera']});await pending;
  assert.equal(f.snapshot().local.getVideoTracks()[0].getSettings().deviceId,'unplugged-camera');
});
