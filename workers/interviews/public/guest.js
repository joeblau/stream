// Capability remains in memory; never put it into a URL, storage or diagnostic log.
import {GuestPublicChatView} from './public-chat.js';
const params = new URLSearchParams(location.search);
const room = params.get('room'); let secret = location.hash.slice(1);
history.replaceState(null, '', location.pathname + location.search);
const $ = id => document.getElementById(id);
const status = text => { $('status').textContent = text; };
const publicChat = new GuestPublicChatView({messages:$('public-messages'),status:$('public-chat-status'),sources:$('public-sources'),document});
let local, shared, socket, pc, audio, analyser, meterSource, meterFrame, generation, host, hostGeneration;
let signalQueue = {pending:0};
let candidateQueue = [], signalChain = Promise.resolve(), left = false, name = 'Guest';
let relayTimer, deviceEpoch = 0, activeNegotiation, cachedRelay;
let deviceCommit = Promise.resolve();
let committedDevices = {}; // Page-memory device intent changes only with a committed capture.
const deviceTracks = new Set();
let control, mediaSenders = {}, screenApproved = false, shareEpoch = 0, pendingDisplay = false;
const MEDIA_CONTROL = 'stream-interview-control-v1';
const privateMessages = [], privatePending = new Map();
let privateSupported=false;
let privateTimer, privateRateStart=0, privateIncoming=0, privateOutgoing=0, privateAcknowledgments=0;
const privateID=value=>typeof value==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const privateText=value=>typeof value==='string' && value.trim().length>0 && new TextEncoder().encode(value).length<=512 && !/[\x00-\x08\x0b-\x1f\x7f]/.test(value);
function updatePrivateControls() {
  const open=admitted && privateSupported && control?.readyState==='open';
  $('message').disabled=!open;$('sendmessage').disabled=!open || privatePending.size>=8 || !privateText($('message').value);
}
function clearPrivateMessages() {
  clearInterval(privateTimer);privateTimer=undefined;privatePending.clear();privateMessages.length=0;
  privateSupported=false;privateRateStart=0;privateIncoming=privateOutgoing=privateAcknowledgments=0;
  $('messages').replaceChildren();$('message').value='';
  $('message-status').textContent='Connect to the admitted host to send messages.';updatePrivateControls();
}
function privateRate() {
  const now=performance.now();if(now-privateRateStart>=1000){privateRateStart=now;privateIncoming=privateOutgoing=privateAcknowledgments=0;}
}
function privateSend(value) {
  if(!admitted || control?.readyState!=='open' || control.bufferedAmount>8192)return false;
  const text=JSON.stringify({...value,negotiation:activeNegotiation});if(new TextEncoder().encode(text).length>1024)return false;
  try{control.send(text);return true;}catch{return false;}
}
function appendPrivateMessage(id,text,fromHost,delivery) {
  if(privateMessages.length>=64){const index=privateMessages.findIndex(value=>!privatePending.has(value.id));if(index<0)return false;privateMessages.splice(index,1);$('messages').children[index].remove();}
  const paragraph=document.createElement('p'),body=document.createElement('span'),receipt=document.createElement('small');
  body.textContent=(fromHost?'Host: ':'You: ')+text;receipt.textContent=delivery;paragraph.append(body,receipt);$('messages').append(paragraph);
  privateMessages.push({id,fromHost,receipt});return true;
}
function receivePrivate(value) {
  if(!value || value.negotiation!==activeNegotiation)return false;
  if(value.type==='private-message-capability' && Object.keys(value).length===3 && typeof value.enabled==='boolean') {
    privateSupported=value.enabled;$('message-status').textContent=privateSupported?'Private messages are available for this host connection.':'This host does not provide private messages.';updatePrivateControls();return true;
  }
  if(!privateSupported || !privateID(value.id))return false;
  privateRate();
  if(value.type==='private-message' && Object.keys(value).length===4 && privateText(value.text)) {
    if(privateIncoming>=8)return true;privateIncoming++;
    const previous=privateMessages.find(message=>message.id===value.id);
    if(previous && !previous.fromHost)return true;
    if(!previous && !appendPrivateMessage(value.id,value.text,true,'Received'))return true;
    privateSend({type:'private-message-ack',id:value.id});return true;
  }
  if(value.type==='private-message-ack' && Object.keys(value).length===3) {
    if(privateAcknowledgments>=32)return true;privateAcknowledgments++;
    const pending=privatePending.get(value.id);if(pending){privatePending.delete(value.id);pending.receipt.textContent='Host received';updatePrivateControls();}return true;
  }
  return false;
}
$('message').oninput=updatePrivateControls;
$('sendmessage').onclick=()=>{
  privateRate();const text=$('message').value;
  if(!privateSupported || !privateText(text) || privatePending.size>=8 || privateOutgoing>=8)return;
  const id=crypto.randomUUID();if(!privateSend({type:'private-message',id,text})){$('message-status').textContent='Message was not sent. Check the host connection.';return;}
  privateOutgoing++;appendPrivateMessage(id,text,false,'Waiting for host receipt');
  privatePending.set(id,{receipt:privateMessages.at(-1).receipt,expires:performance.now()+10000});$('message').value='';
  $('message-status').textContent='Private message sent once; waiting for a host receipt.';updatePrivateControls();
  privateTimer??=setInterval(()=>{const now=performance.now();for(const[id,pending]of privatePending){if(now>=pending.expires){pending.receipt.textContent='Delivery unknown';privatePending.delete(id);}}updatePrivateControls();if(!privatePending.size){clearInterval(privateTimer);privateTimer=undefined;}},100);
};
let joinEpoch = 0, admitted = false, cameraEnabled = true, microphoneEnabled = true;
const valid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(room ?? '') && /^[0-9a-f]{64}$/.test(secret);
if (!valid) { status('This invite is incomplete. Ask the host for a fresh link.'); $('prepare').disabled = true; }
function devicesReady(stream=local, kind) {
  return !!stream && (kind ? [kind] : ['audio','video']).every(required =>
    stream.getTracks().some(track => track.kind===required && track.readyState==='live'));
}
function updateJoinReadiness() { $('join').disabled=left || !valid || !devicesReady() || socket?.readyState===WebSocket.OPEN; }
function controls(enabled) { for (const id of ['mute','hide','tone']) $(id).disabled = !enabled; updateJoinReadiness(); }
function resetPeer() {
  ++deviceEpoch; deviceTracks.forEach(track => track.stop()); $('prepare').disabled = left || !valid;
  clearTimeout(relayTimer); relayTimer = undefined;
  stopShare();control?.close();control=undefined;mediaSenders={};screenApproved=false;updateShareControls();clearPrivateMessages();publicChat.reset();
  admitted = false; host = hostGeneration = activeNegotiation = undefined; candidateQueue = [];
  pc?.close(); pc = undefined; $('return').srcObject = null;
  $('program').textContent='Program and recording status unavailable while disconnected.';
}
function updateShareControls() {
  $('share').disabled=!admitted || !screenApproved || control?.readyState!=='open' || !!shared || pendingDisplay;
  $('stopshare').disabled=!shared;
  $('share-status').textContent=shared?'Screen sharing active; camera and microphone remain connected':screenApproved?pendingDisplay?'Finish or cancel the open screen chooser before trying again.':'The host approved screen sharing. Choose a screen when ready.':'Screen sharing requires admission and explicit host approval.';
}
function screenState(sharing) {
  if(control?.readyState!=='open')return false;
  try{if(control.bufferedAmount>8192)throw new Error('Control backlog');control.send(JSON.stringify({type:'screen-state',negotiation:activeNegotiation,sharing}));return true;}
  catch{screenApproved=false;control.close();return false;}
}
function stopShare() {
  ++shareEpoch;const previous=shared;shared=undefined;
  previous?.getTracks().forEach(track=>track.stop());
  mediaSenders.screen?.replaceTrack(null).catch(()=>{});
  if(previous)screenState(false);updateShareControls();
}
function send(value) { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value)); }
function signal(kind, payload) { send({type:'signal', to:host, targetGeneration:hostGeneration, kind, payload:JSON.stringify(payload)}); }
async function enumerate() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  for (const [id, kind] of [['camera','videoinput'],['microphone','audioinput']]) {
    const trackKind = kind==='videoinput'?'video':'audio';
    const select = $(id), selected = committedDevices[trackKind] ?? local?.getTracks().find(t => t.kind===trackKind)?.getSettings().deviceId;
    select.replaceChildren();
    for (const device of devices.filter(d => d.kind === kind)) { const option = document.createElement('option'); option.value = device.deviceId; option.textContent = device.label || `Device ${select.length + 1}`; select.append(option); }
    if (selected && !devices.some(device => device.kind===kind && device.deviceId===selected)) {
      const missing=document.createElement('option');missing.value=selected;missing.disabled=true;
      missing.textContent='Selected device unavailable — choose another device';select.append(missing);
    }
    if (selected) select.value = selected;
  }
}
function watchTracks(stream) {
  for (const track of stream.getTracks()) track.addEventListener('ended', () => {
    if (local?.getTracks().includes(track)) {
      updateJoinReadiness();
      if(track.kind==='audio')$('level').value=0;
      status(`${track.kind === 'audio' ? 'Microphone' : 'Camera'} access ended. Restore site permission and check devices again with this invite.`);
    }
  });
}
async function startMeter() {
  cancelAnimationFrame(meterFrame); meterSource?.disconnect(); analyser?.disconnect();
  audio ??= new AudioContext(); audio.resume().catch(()=>{});
  analyser = audio.createAnalyser(); analyser.fftSize = 512;
  meterSource = audio.createMediaStreamSource(local); meterSource.connect(analyser);
  const samples = new Float32Array(analyser.fftSize);
  const tick = () => { analyser.getFloatTimeDomainData(samples); $('level').value = microphoneEnabled ? Math.min(1, Math.sqrt(samples.reduce((sum,v) => sum+v*v,0)/samples.length)*4) : 0; meterFrame = requestAnimationFrame(tick); }; tick();
}
// Capture permission dialogs may finish after Leave, a new check, or a media
// restart. Serialize sender writes, then publish the complete local stream only
// after every replacement succeeds. Failed changes retain the previous devices.
async function installDevices(fresh, epoch, kind, requestedDevices={}) {
  if (left || epoch !== deviceEpoch) return false;
  fresh.getTracks().forEach(track => deviceTracks.add(track));
  const install = async () => {
    const previous = local, senders = mediaSenders;
    const current = () => !left && epoch === deviceEpoch && local === previous && mediaSenders === senders;
    if (!current()) return false;
    if (!devicesReady(fresh, kind)) throw new Error('Device access ended before installation');
    const replaced = [];
    try {
      for (const track of fresh.getTracks()) {
        track.enabled = track.kind === 'audio' ? microphoneEnabled : cameraEnabled;
        const sender = senders[track.kind === 'audio' ? 'audio' : 'camera'];
        if (sender) {
          const old = sender.track;
          await sender.replaceTrack(track); replaced.push({sender, track, old});
          if (!current() || !devicesReady(fresh, kind)) throw new Error('Device change superseded or access ended');
        }
      }
      if (!current() || !devicesReady(fresh, kind)) throw new Error('Device change superseded or access ended');
      fresh.getTracks().forEach(track => { track.enabled = track.kind === 'audio' ? microphoneEnabled : cameraEnabled; });
      const nextDevices = {...committedDevices};
      for (const track of fresh.getTracks()) {
        const id = requestedDevices[track.kind] ?? track.getSettings().deviceId;
        if (typeof id==='string' && id) nextDevices[track.kind]=id;
      }
      const nextLocal = kind ? new MediaStream([...previous.getTracks().filter(track => track.kind !== kind), ...fresh.getTracks()]) : fresh;
      // A failed, cancelled or superseded replacement never commits selection
      // intent. Enumeration and browser defaults cannot choose new hardware.
      local = nextLocal; committedDevices = nextDevices;
      watchTracks(fresh); $('preview').srcObject = local;
      previous?.getTracks().filter(track => !kind || track.kind === kind).forEach(track => track.stop());
      return true;
    } catch (error) {
      // Restore only this transaction's live senders; never touch a new peer.
      let restoreFailed = false;
      for (const {sender, track, old} of replaced.reverse()) {
        if (!left && mediaSenders === senders && sender.track === track) {
          try { await sender.replaceTrack(old ?? null); } catch { restoreFailed = true; }
        }
      }
      if (restoreFailed && !left && mediaSenders === senders) {
        resetPeer();
        status('Device recovery could not restore host media. Reconnect with this invite and ask the host to admit you again.');
      }
      throw error;
    }
  };
  const pending = deviceCommit.then(install);
  deviceCommit = pending.catch(() => {});
  try { return await pending; }
  finally { fresh.getTracks().forEach(track => deviceTracks.delete(track)); }
}
async function prepare() {
  const epoch = ++deviceEpoch, requestedDevices = {...committedDevices};
  $('prepare').disabled = true;
  let fresh, installed = false;
  try {
    // Resume during the explicit click, before a permission dialog or await.
    audio ??= new AudioContext(); audio.resume().catch(()=>{});
    // Rechecking permission must not silently replace a chosen device with a
    // browser default. A missing exact choice requires deliberate reselection.
    fresh = await navigator.mediaDevices.getUserMedia({
      audio:{echoCancellation:true,noiseSuppression:true,...(requestedDevices.audio?{deviceId:{exact:requestedDevices.audio}}:{})},
      video:{width:{ideal:1280},height:{ideal:720},...(requestedDevices.video?{deviceId:{exact:requestedDevices.video}}:{})}
    });
    installed = await installDevices(fresh, epoch, undefined, requestedDevices);
    if (!installed || epoch !== deviceEpoch || left) return;
    controls(true);
    await enumerate();
    if (epoch !== deviceEpoch || left) return;
    await startMeter();
    if (epoch === deviceEpoch && !left) status(admitted ? 'Devices restored. Your host connection remains active.' : 'Device check ready. Join the waiting room when you are ready.');
  } catch (error) {
    if (epoch === deviceEpoch && !left) {
      if (error.name==='NotAllowedError') status('Camera or microphone permission was denied. Allow access in site settings, then check again. Your selected devices will be retried.');
      else if ((requestedDevices.audio || requestedDevices.video) && ['NotFoundError','OverconstrainedError'].includes(error.name)) status('A selected device is unavailable. Restore it or choose another device. Your previous devices and invite are preserved.');
      else status(devicesReady() ? 'Device check failed. Any previous devices and your invite remain active. Check connections and try again.' : 'Device check failed. Restore camera and microphone access, then check again with this invite.');
    }
  } finally {
    if (!installed) fresh?.getTracks().forEach(track => track.stop());
    updateJoinReadiness();
    if (epoch === deviceEpoch || left) $('prepare').disabled = left;
  }
}
async function switchDevice(kind, id) {
  if (!local || left) return;
  if (!['audio','video'].includes(kind) || typeof id!=='string' || !id) { status('Choose an available camera or microphone.'); return; }
  const epoch = ++deviceEpoch;
  let fresh, installed = false;
  try {
    fresh = await navigator.mediaDevices.getUserMedia(kind==='video' ? {video:{deviceId:{exact:id}},audio:false} : {audio:{deviceId:{exact:id},echoCancellation:true},video:false});
    installed = await installDevices(fresh, epoch, kind, {[kind]:id});
    if (!installed || epoch !== deviceEpoch || left) return;
    updateJoinReadiness();
    if (kind==='audio') await startMeter(); await enumerate();
  } catch {
    if (epoch === deviceEpoch && !left) {
      const selected=committedDevices[kind];if(selected)$(kind==='video'?'camera':'microphone').value=selected;
      status(devicesReady() ? 'Device change failed. Your previous device and invite remain active.' : 'Device change failed. Restore the missing device and check again with this invite.');
    }
  } finally {
    if (!installed) fresh?.getTracks().forEach(track => track.stop());
    updateJoinReadiness();
    if (epoch === deviceEpoch && !left) $('prepare').disabled = false;
  }
}
async function iceServers() {
  if (cachedRelay && Date.now() < cachedRelay.expires) return cachedRelay.servers;
  const response = await fetch(`/v1/rooms/${room}/turn`,{method:'POST',headers:{Authorization:`Bearer ${secret}`},signal:AbortSignal.timeout(10000)});
  if (!response.ok) throw new Error(response.status===503 ? 'TURN service is unavailable. The host must configure relay credentials.' : 'Unable to obtain relay credentials. Try reconnecting after a minute.');
  const data = await response.json();
  if (!Array.isArray(data.iceServers)) throw new Error('Invalid relay configuration');
  cachedRelay = {servers:data.iceServers,expires:Date.now()+480000};
  return data.iceServers;
}
function stereoAudioAnswer(description, audioMID) {
  if(description.type!=='answer' || typeof description.sdp!=='string' || description.sdp.length>65536)throw new Error('Invalid host media answer.');
  const sections=description.sdp.split(/(?=^m=)/m);
  const audio=sections.findIndex(section=>section.startsWith('m=audio ') && section.split('\r\n').includes(`a=mid:${audioMID}`));
  if(audio<0)throw new Error('The host audio identity is unavailable.');
  const lines=sections[audio].split('\r\n'), opus=lines.map(line=>/^a=rtpmap:(\d+) opus\/48000\/2$/i.exec(line)).find(Boolean);
  if(!opus)throw new Error('The host audio codec is unavailable.');
  const prefix=`a=fmtp:${opus[1]} `, index=lines.findIndex(line=>line.startsWith(prefix));
  const parameters=index<0?[]:lines[index].slice(prefix.length).split(';').filter(value=>!/^\s*(?:stereo|sprop-stereo)\s*=/.test(value));
  // RFC7587 stereo is a receiver preference; Chrome's default answer omits
  // it and downmixes a real stereo return despite the host's stereo offer.
  const fmtp=prefix+[...parameters,'stereo=1','sprop-stereo=1'].join(';');
  if(index<0)lines.splice(lines.length-1,0,fmtp);else lines[index]=fmtp;
  sections[audio]=lines.join('\r\n');
  return {type:'answer',sdp:sections.join('')};
}
async function acceptSignal(data, epoch) {
  if (epoch!==joinEpoch || data.targetGeneration!==generation || data.from!==host || data.generation!==hostGeneration || !admitted) return;
  const payload = JSON.parse(data.payload);
  if (data.kind === 'reset') { resetPeer(); status('Host restarted the media connection. Waiting for admission.'); return; }
  if (data.kind === 'offer') {
    if (!payload || !/^[0-9a-f-]{36}$/.test(payload.negotiation ?? '') || payload.description?.type!=='offer') return;
    const identities=payload.media, mids=['audio','camera','screen'].map(kind=>identities?.[kind]);
    if(mids.some(mid=>typeof mid!=='string' || !/^[0-9A-Za-z_-]{1,16}$/.test(mid)) || new Set(mids).size!==3)throw new Error('The host must offer separate camera and screen sources.');
    // An ended permission/device track is not a prepared source. Preserve the
    // existing peer/invite until deliberate recovery instead of answering with
    // an already-dead capture or closing a healthy remaining source.
    if (!devicesReady()) { updateJoinReadiness(); throw new Error('Restore camera and microphone access and check devices again, then reconnect with this invite.'); }
    const negotiation = payload.negotiation;
    activeNegotiation = negotiation; clearTimeout(relayTimer); stopShare();clearPrivateMessages();publicChat.reset(negotiation);
    control?.close();control=undefined;mediaSenders={};screenApproved=false;updateShareControls();
    pc?.close(); $('return').srcObject = null;
    const next = new RTCPeerConnection({iceServers:await iceServers()});
    if (epoch!==joinEpoch || !admitted || activeNegotiation!==negotiation || hostGeneration!==data.generation || host!==data.from) { next.close(); return; } pc = next;
    const current=()=>epoch===joinEpoch && admitted && pc===next && activeNegotiation===negotiation && hostGeneration===data.generation && host===data.from;
    // Native Program return uses an explicit visibility control; reference
    // hosts retain their existing immediately visible negotiated video path.
    let returnVideoTrack, returnVideoAllowed=!/^a=ssrc:\d+ msid:stream-return video-return\r?$/m.test(payload.description.sdp);
    const attachReturnStream=()=>{
      const nextStream=returnStream.getTracks().length?returnStream:null;
      // Reassigning even the same MediaStream invokes the HTML load algorithm
      // and replaces its normal audio/video renderer. Track membership changes
      // already notify that renderer; preserve it for this full negotiation.
      if($('return').srcObject!==nextStream)$('return').srcObject=nextStream;
    };
    const updateReturnVideo=()=>{
      const desired=returnVideoAllowed&&returnVideoTrack?.readyState==='live'?returnVideoTrack:undefined;
      for(const track of returnStream.getVideoTracks())if(track!==desired)returnStream.removeTrack(track);
      if(desired&&!returnStream.getVideoTracks().includes(desired))returnStream.addTrack(desired);
      attachReturnStream();
    };
    next.ondatachannel=event=>{
      const channel=event.channel;
      if(!current() || channel.label!==MEDIA_CONTROL || control){channel.close();return;}
      control=channel;
      channel.onopen=()=>{if(current()){updateShareControls();updatePrivateControls();}};
      channel.onclose=()=>{if(current() && control===channel){screenApproved=false;stopShare();updateShareControls();clearPrivateMessages();publicChat.reset();}};
      channel.onmessage=event=>{
        if(!current() || control!==channel || typeof event.data!=='string' || new TextEncoder().encode(event.data).length>1024)return;
        let value;try{value=JSON.parse(event.data);}catch{return;}
        if(value?.type==='return-video'&&value.negotiation===negotiation&&typeof value.enabled==='boolean'){
          returnVideoAllowed=value.enabled;updateReturnVideo();return;
        }
        if(publicChat.receive(value))return;
        if(receivePrivate(value))return;
        if(value?.type!=='screen-approval' || value.negotiation!==negotiation || typeof value.approved!=='boolean')return;
        screenApproved=value.approved;if(!screenApproved)stopShare();updateShareControls();
      };
    };
    const refreshRelay = async () => {
      try { const servers = await iceServers(); if(pc===next) { next.setConfiguration({iceServers:servers}); relayTimer=setTimeout(refreshRelay,480000); } }
      catch { if(pc===next) { status('Relay credential refresh failed. Reconnect before relay access expires.'); relayTimer=setTimeout(refreshRelay,60000); } }
    };
    clearTimeout(relayTimer); relayTimer=setTimeout(refreshRelay,480000);
    next.onicecandidate = event => { if(event.candidate && pc===next) signal('candidate',{negotiation,candidate:event.candidate.toJSON()}); };
    const returnStream = new MediaStream();
    next.ontrack = event => {
      if(!current())return;
      const kind=event.transceiver.mid===identities.audio?'audio':event.transceiver.mid===identities.camera?'video':undefined;
      if(!kind || event.track.kind!==kind)return;
      if(kind==='video'){
        returnVideoTrack=event.track;updateReturnVideo();
        event.track.addEventListener('ended',()=>{if(current()&&returnVideoTrack===event.track){returnVideoTrack=undefined;updateReturnVideo();}});
        return;
      }
      for(const previous of returnStream.getTracks().filter(track=>track.kind===kind)){returnStream.removeTrack(previous);previous.stop();}
      returnStream.addTrack(event.track);attachReturnStream();
      event.track.addEventListener('ended',()=>{if(current() && $('return').srcObject===returnStream){returnStream.removeTrack(event.track);if(!returnStream.getTracks().length)$('return').srcObject=null;}});
      $('return').play().catch(()=>{if(current())status('Press Play on the host return feed to hear the show.');});
    };
    next.onconnectionstatechange = () => { if(pc===next) status(`Host media: ${next.connectionState}.`); };
    await next.setRemoteDescription(payload.description);
    if(!current())return;
    // Initial negotiation and device changes share one sender-write queue.
    // Otherwise a slow initial replacement can reinstall a stopped old track.
    const attach = deviceCommit.then(async () => {
      if (!current()) return;
      if (!devicesReady()) { next.close(); throw new Error('Device access ended. Check camera and microphone again before reconnecting with this invite.'); }
      for(const [kind,trackKind]of [['audio','audio'],['camera','video'],['screen','video']]) {
        const transceiver=next.getTransceivers().find(value=>value.mid===identities[kind]);
        if(!transceiver || transceiver.receiver.track.kind!==trackKind){next.close();throw new Error('Host media identities do not match the offered tracks.');}
        mediaSenders[kind]=transceiver.sender;transceiver.direction=kind==='screen'?'sendonly':'sendrecv';
        if(kind!=='screen') {
          const track=local?.getTracks().find(value=>value.kind===trackKind && value.readyState==='live');
          if(!track || track.readyState!=='live'){next.close();throw new Error('Check camera and microphone before joining.');}
          transceiver.sender.setStreams(local);await transceiver.sender.replaceTrack(track);
          if(!current())return;
          if(!devicesReady()){next.close();throw new Error('Device access ended. Check camera and microphone again before reconnecting with this invite.');}
        }
      }
    });
    deviceCommit = attach.catch(() => {});
    await attach;
    if (!current()) return;
    for(const candidate of candidateQueue.filter(value=>value.negotiation===negotiation)) {
      try { await next.addIceCandidate(candidate.candidate); } catch { status('A relay candidate was rejected; checking remaining paths.'); }
      if(!current())return;
    }
    candidateQueue = [];
    const answer=stereoAudioAnswer(await next.createAnswer(),identities.audio);if(!current())return;
    await next.setLocalDescription(answer);if(!current())return;
    signal('answer',{negotiation,description:next.localDescription});updateShareControls();
  } else if (data.kind === 'candidate') {
    if (!payload || !/^[0-9a-f-]{36}$/.test(payload.negotiation ?? '') || !payload.candidate) return;
    if(pc?.remoteDescription && payload.negotiation===activeNegotiation) {
      try { await pc.addIceCandidate(payload.candidate); } catch { status('A relay candidate was rejected; checking remaining paths.'); }
    } else if(!pc && candidateQueue.length<128) candidateQueue.push(payload);
  }
}
function join() {
  if (left || !valid) return;
  if (!devicesReady()) { updateJoinReadiness(); status('Restore camera and microphone access and check devices again before joining with this invite.'); return; }
  const epoch = ++joinEpoch; signalQueue={pending:0}; signalChain=Promise.resolve(); resetPeer(); socket?.close(); name=$('name').value.trim()||'Guest';
  socket = new WebSocket(`${location.protocol==='https:'?'wss:':'ws:'}//${location.host}/v1/rooms/${room}/socket`,['stream-interview-v1',`cap.${secret}`]);
  socket.onopen=()=>{if(epoch!==joinEpoch)return;send({type:'hello',name});status('Waiting for the host to admit you.');$('join').disabled=true;$('rejoin').disabled=false;$('leave').disabled=false;};
  socket.onmessage=event=>{
    if(epoch!==joinEpoch)return;
    let data;try{data=JSON.parse(event.data);}catch{return;}
    if(Number.isSafeInteger(data.delivery))send({type:'ack',delivery:data.delivery});
    if(data.type==='welcome'){generation=data.generation;return;}
    if(data.type==='admitted'){admitted=true;host=data.host;hostGeneration=data.hostGeneration;status(data.state==='onair'?'Host marked you on air.':'Admitted backstage.');return;}
    if(data.type==='roster'){$('program').textContent=`Program ${data.program?'live':'offline'} · Recording ${data.recording?'active':'off'}`;return;}
    if(data.type==='host-disconnected'){resetPeer();status('Host disconnected. Waiting for the host to return and admit you again.');return;}
    if(data.type==='ended'){leave('The host ended this interview. Open a new invite to return.');return;}
    if(data.type==='signal'){
      const queue=signalQueue;
      if(queue.pending>=32){socket.close(1008,'Signal processing capacity exceeded');resetPeer();status('Media signaling exceeded capacity. Reconnect to try again.');return;}
      queue.pending++;
      signalChain=signalChain.then(()=>acceptSignal(data,epoch)).catch(error=>{if(epoch===joinEpoch)status(error.message);}).finally(()=>{queue.pending--;});
    }
  };
  socket.onclose=event=>{if(epoch!==joinEpoch)return;if(event.code===4003){leave('This invite was revoked. Open a new invite from the host.');return;}resetPeer();status(devicesReady() ? 'Disconnected. Reconnect with this invite while it remains valid.' : 'Disconnected. Restore camera and microphone access and check devices again with this invite.');updateJoinReadiness();};
  socket.onerror=()=>{if(epoch===joinEpoch)status('Connection failed. Check your network and invite.');};
}
async function leave(message='You left. Camera and microphone are stopped. Open the invite again to return.') {
  left=true;secret='';cachedRelay=undefined;++joinEpoch;++deviceEpoch;socket?.close();socket=undefined;resetPeer();
  local?.getTracks().forEach(t=>t.stop());local=undefined;$('preview').srcObject=null;
  cancelAnimationFrame(meterFrame);await audio?.close();audio=undefined;$('level').value=0;
  controls(false);$('prepare').disabled=true;$('rejoin').disabled=true;$('leave').disabled=true;status(message);
}
$('prepare').onclick=()=>{left=false;prepare();};$('join').onclick=join;$('rejoin').onclick=join;$('leave').onclick=()=>leave();
$('camera').onchange=()=>switchDevice('video',$('camera').value);$('microphone').onchange=()=>switchDevice('audio',$('microphone').value);
$('mute').onclick=()=>{microphoneEnabled=!microphoneEnabled;local?.getAudioTracks().forEach(t=>t.enabled=microphoneEnabled);deviceTracks.forEach(t=>{if(t.kind==='audio')t.enabled=microphoneEnabled;});$('mute').textContent=microphoneEnabled?'Mute microphone':'Unmute microphone';};
$('hide').onclick=()=>{cameraEnabled=!cameraEnabled;local?.getVideoTracks().forEach(t=>t.enabled=cameraEnabled);deviceTracks.forEach(t=>{if(t.kind==='video')t.enabled=cameraEnabled;});$('hide').textContent=cameraEnabled?'Turn camera off':'Turn camera on';};
$('tone').onclick=async()=>{if(!audio)return;await audio.resume();const tone=audio.createOscillator(),gain=audio.createGain();tone.frequency.value=440;gain.gain.value=.03;tone.connect(gain).connect(audio.destination);tone.start();tone.stop(audio.currentTime+.3);};
$('share').onclick=async()=>{
  if(!pc || !admitted || !screenApproved || control?.readyState!=='open' || !mediaSenders.screen || shared || pendingDisplay)return;
  const expected=pc,negotiation=activeNegotiation,sender=mediaSenders.screen,epoch=++shareEpoch;
  const current=()=>pc===expected && admitted && screenApproved && activeNegotiation===negotiation && mediaSenders.screen===sender && epoch===shareEpoch;
  pendingDisplay=true;updateShareControls();
  let captured;
  try{
    captured=await navigator.mediaDevices.getDisplayMedia({video:true,audio:false});
    if(!current()){captured.getTracks().forEach(t=>t.stop());return;}
    const track=captured.getVideoTracks()[0];if(!track)throw new Error('No screen track');
    shared=captured;track.onended=()=>{if(shared===captured){stopShare();status('Screen sharing stopped. Camera and microphone remain connected.');}};
    await sender.replaceTrack(track);
    if(!current()){captured.getTracks().forEach(t=>t.stop());if(shared===captured)stopShare();return;}
    if(!screenState(true)){stopShare();status('Screen controls are unavailable. Camera and microphone remain connected.');return;}
    status('Screen shared as a separate source with the approved host.');
  }catch{const stillCurrent=current();captured?.getTracks().forEach(t=>t.stop());if(captured && shared===captured)stopShare();if(stillCurrent)status('Screen sharing was cancelled or unavailable. Camera and microphone remain connected.');}
  finally{pendingDisplay=false;updateShareControls();}
};
$('stopshare').onclick=()=>{stopShare();status('Screen sharing stopped. Camera and microphone remain connected.');};
navigator.mediaDevices?.addEventListener('devicechange',()=>enumerate().catch(()=>status('Devices changed. Check camera and microphone again.')));
window.addEventListener('pagehide',()=>{secret='';leave();});
