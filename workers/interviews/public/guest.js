// Capability remains in memory; never put it into a URL, storage or diagnostic log.
const params = new URLSearchParams(location.search);
const room = params.get('room'); let secret = location.hash.slice(1);
history.replaceState(null, '', location.pathname + location.search);
const $ = id => document.getElementById(id);
const status = text => { $('status').textContent = text; };
let local, shared, socket, pc, audio, analyser, meterSource, meterFrame, generation, host, hostGeneration;
let signalQueue = {pending:0};
let candidateQueue = [], signalChain = Promise.resolve(), left = false, name = 'Guest';
let relayTimer, deviceEpoch = 0, activeNegotiation, cachedRelay;
let control, mediaSenders = {}, screenApproved = false, shareEpoch = 0, pendingDisplay = false;
const MEDIA_CONTROL = 'stream-interview-control-v1';
let joinEpoch = 0, admitted = false, cameraEnabled = true, microphoneEnabled = true;
const valid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(room ?? '') && /^[0-9a-f]{64}$/.test(secret);
if (!valid) { status('This invite is incomplete. Ask the host for a fresh link.'); $('prepare').disabled = true; }
function controls(enabled) { for (const id of ['mute','hide','tone','join']) $(id).disabled = !enabled; }
function resetPeer() {
  clearTimeout(relayTimer); relayTimer = undefined;
  stopShare();control?.close();control=undefined;mediaSenders={};screenApproved=false;updateShareControls();
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
    const select = $(id), selected = local?.getTracks().find(t => t.kind === (kind === 'videoinput' ? 'video' : 'audio'))?.getSettings().deviceId;
    select.replaceChildren();
    for (const device of devices.filter(d => d.kind === kind)) { const option = document.createElement('option'); option.value = device.deviceId; option.textContent = device.label || `Device ${select.length + 1}`; select.append(option); }
    if (selected) select.value = selected;
  }
}
function watchTracks(stream) {
  for (const track of stream.getTracks()) track.addEventListener('ended', () => {
    if (local?.getTracks().includes(track)) status(`${track.kind === 'audio' ? 'Microphone' : 'Camera'} access ended. Restore site permission and check devices again.`);
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
async function prepare() {
  $('prepare').disabled = true;
  try {
    // Resume during the explicit click, before a permission dialog or await.
    audio ??= new AudioContext(); audio.resume().catch(()=>{});
    const fresh = await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true},video:{width:{ideal:1280},height:{ideal:720}}});
    if (left) { fresh.getTracks().forEach(t=>t.stop()); return; }
    const old = local;
    for (const track of fresh.getTracks()) {
      track.enabled = track.kind === 'audio' ? microphoneEnabled : cameraEnabled;
      const sender = mediaSenders[track.kind==='audio'?'audio':'camera'];
      if (sender) await sender.replaceTrack(track);
    }
    local = fresh; watchTracks(local); $('preview').srcObject = local;
    old?.getTracks().forEach(t=>t.stop()); await enumerate(); await startMeter(); controls(true);
    status('Device check ready. Join the waiting room when you are ready.');
  } catch (error) { status(error.name === 'NotAllowedError' ? 'Camera or microphone permission was denied. Allow access in site settings, then check again.' : 'Devices are unavailable. Connect a camera and microphone, then check again.'); }
  finally { $('prepare').disabled = false; }
}
async function switchDevice(kind, id) {
  const epoch = ++deviceEpoch;
  let fresh;
  try {
    fresh = await navigator.mediaDevices.getUserMedia(kind==='video' ? {video:{deviceId:{exact:id}},audio:false} : {audio:{deviceId:{exact:id},echoCancellation:true},video:false});
    if (epoch!==deviceEpoch || !local || left) { fresh.getTracks().forEach(t=>t.stop()); return; }
    const track = fresh.getTracks()[0]; track.enabled = kind==='audio' ? microphoneEnabled : cameraEnabled;
    const old = local.getTracks().find(t=>t.kind===kind);
    const sender = mediaSenders[kind==='audio'?'audio':'camera']; if (sender) await sender.replaceTrack(track);
    local.removeTrack(old); local.addTrack(track); old.stop(); watchTracks(fresh); $('preview').srcObject = local;
    if (kind==='audio') await startMeter(); await enumerate();
  } catch { fresh?.getTracks().forEach(t=>t.stop()); status('Device change failed. Your previous device and invite remain active.'); }
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
async function acceptSignal(data, epoch) {
  if (epoch!==joinEpoch || data.targetGeneration!==generation || data.from!==host || data.generation!==hostGeneration || !admitted) return;
  const payload = JSON.parse(data.payload);
  if (data.kind === 'reset') { resetPeer(); status('Host restarted the media connection. Waiting for admission.'); return; }
  if (data.kind === 'offer') {
    if (!payload || !/^[0-9a-f-]{36}$/.test(payload.negotiation ?? '') || payload.description?.type!=='offer') return;
    const identities=payload.media, mids=['audio','camera','screen'].map(kind=>identities?.[kind]);
    if(mids.some(mid=>typeof mid!=='string' || !/^[0-9A-Za-z_-]{1,16}$/.test(mid)) || new Set(mids).size!==3)throw new Error('The host must offer separate camera and screen sources.');
    const negotiation = payload.negotiation;
    activeNegotiation = negotiation; clearTimeout(relayTimer); stopShare();
    control?.close();control=undefined;mediaSenders={};screenApproved=false;updateShareControls();
    pc?.close(); const next = new RTCPeerConnection({iceServers:await iceServers()});
    if (epoch!==joinEpoch || !admitted || activeNegotiation!==negotiation || hostGeneration!==data.generation || host!==data.from) { next.close(); return; } pc = next;
    const current=()=>epoch===joinEpoch && admitted && pc===next && activeNegotiation===negotiation && hostGeneration===data.generation && host===data.from;
    next.ondatachannel=event=>{
      const channel=event.channel;
      if(!current() || channel.label!==MEDIA_CONTROL || control){channel.close();return;}
      control=channel;
      channel.onopen=()=>{if(current())updateShareControls();};
      channel.onclose=()=>{if(current() && control===channel){screenApproved=false;stopShare();updateShareControls();}};
      channel.onmessage=event=>{
        if(!current() || control!==channel || typeof event.data!=='string' || new TextEncoder().encode(event.data).length>1024)return;
        let value;try{value=JSON.parse(event.data);}catch{return;}
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
    next.ontrack = event => { if(pc===next) $('return').srcObject = event.streams[0] ?? new MediaStream([event.track]); };
    next.onconnectionstatechange = () => { if(pc===next) status(`Host media: ${next.connectionState}.`); };
    await next.setRemoteDescription(payload.description);
    if(!current())return;
    for(const [kind,trackKind]of [['audio','audio'],['camera','video'],['screen','video']]) {
      const transceiver=next.getTransceivers().find(value=>value.mid===identities[kind]);
      if(!transceiver || transceiver.receiver.track.kind!==trackKind){next.close();throw new Error('Host media identities do not match the offered tracks.');}
      mediaSenders[kind]=transceiver.sender;transceiver.direction=kind==='screen'?'sendonly':'sendrecv';
      if(kind!=='screen') {
        const track=local?.getTracks().find(value=>value.kind===trackKind);
        if(!track){next.close();throw new Error('Check camera and microphone before joining.');}
        transceiver.sender.setStreams(local);await transceiver.sender.replaceTrack(track);
        if(!current())return;
      }
    }
    for(const candidate of candidateQueue.filter(value=>value.negotiation===negotiation)) {
      try { await next.addIceCandidate(candidate.candidate); } catch { status('A relay candidate was rejected; checking remaining paths.'); }
      if(!current())return;
    }
    candidateQueue = [];
    const answer=await next.createAnswer();if(!current())return;
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
  if (!local || left) return;
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
  socket.onclose=event=>{if(epoch!==joinEpoch)return;if(event.code===4003){leave('This invite was revoked. Open a new invite from the host.');return;}resetPeer();status('Disconnected. Reconnect with this invite while it remains valid.');$('join').disabled=false;};
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
$('mute').onclick=()=>{microphoneEnabled=!microphoneEnabled;local?.getAudioTracks().forEach(t=>t.enabled=microphoneEnabled);$('mute').textContent=microphoneEnabled?'Mute microphone':'Unmute microphone';};
$('hide').onclick=()=>{cameraEnabled=!cameraEnabled;local?.getVideoTracks().forEach(t=>t.enabled=cameraEnabled);$('hide').textContent=cameraEnabled?'Turn camera off':'Turn camera on';};
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
