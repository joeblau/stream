// Test-only reference client. Capabilities/SDP/ICE/relay credentials are never
// written to storage, query strings, logs or third-party services.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const CAPABILITY = /^[0-9a-f]{64}$/;
const byteLength = value => new TextEncoder().encode(value).length;

export class InterviewReferenceHost {
  #secret; #socket; #epoch = 0; #generation; #id; #expiresTimer; #endTimer;
  #relay; #relayRequest; #relayAbort; #relayTimer;
  #outboundICE = []; #iceTimer; #local; #deviceEpoch = 0; #ending = false;
  constructor({location = globalThis.location, history = globalThis.history, WebSocket = globalThis.WebSocket,
    RTCPeerConnection = globalThis.RTCPeerConnection, fetch = (...args) => globalThis.fetch(...args),
    mediaDevices = globalThis.navigator?.mediaDevices, MediaStream = globalThis.MediaStream,
    randomUUID = () => globalThis.crypto.randomUUID(), now = () => Date.now(),
    setTimeout = (fn,delay) => globalThis.setTimeout(fn,delay), clearTimeout = id => globalThis.clearTimeout(id), onChange = () => {}} = {}) {
    this.api = {location, WebSocket, RTCPeerConnection, fetch, mediaDevices, MediaStream, randomUUID, now, setTimeout, clearTimeout};
    this.room = new URLSearchParams(location.search).get('room'); this.#secret = location.hash.slice(1);
    history.replaceState(null, '', location.pathname + location.search);
    this.valid = UUID.test(this.room ?? '') && CAPABILITY.test(this.#secret);
    this.onChange = onChange; this.members = new Map(); this.peers = new Map();
    this.connected = false; this.flags = {locked:false, program:false, recording:false};
    this.status = this.valid ? 'Connect when you are ready.' : 'Incomplete host invite. Reopen a valid host link.';
  }
  changed(text) { if(text) this.status = text; this.onChange(this); }
  get localStream() { return this.#local; }
  get ending() { return this.#ending; }
  #send(value) {
    if(!this.connected || this.#ending || this.#socket?.readyState !== this.api.WebSocket.OPEN || this.#socket.bufferedAmount > 131072) return false;
    const data = JSON.stringify(value); if(byteLength(data) > 60000) return false;
    this.#socket.send(data); return true;
  }
  #signal(record, kind, payload) {
    if(this.peers.get(record.id) !== record || !this.#generation) return false;
    return this.#send({type:'signal',to:record.id,targetGeneration:record.generation,kind,payload:JSON.stringify(payload)});
  }
  connect() {
    if(!this.valid || this.#ending) return;
    this.disconnect(false); const epoch = this.#epoch;
    const {location, WebSocket} = this.api;
    const socket = new WebSocket(`${location.protocol==='https:'?'wss:':'ws:'}//${location.host}/v1/rooms/${this.room}/socket`, ['stream-interview-v1',`cap.${this.#secret}`]);
    this.#socket = socket; this.changed('Connecting reference host…');
    socket.onopen = () => { if(epoch===this.#epoch) { socket.send(JSON.stringify({type:'hello',name:'Reference test host'})); } };
    socket.onmessage = event => {
      if(epoch!==this.#epoch || typeof event.data!=='string' || byteLength(event.data)>65536) return;
      let data; try { data=JSON.parse(event.data); } catch { return; }
      if(!data || typeof data!=='object' || Array.isArray(data)) return;
      // Acknowledge receipt before asynchronous SDP work so one slow media
      // negotiation cannot consume server delivery credit for healthy peers.
      if(Number.isSafeInteger(data.delivery) && data.delivery>0 && socket.readyState===WebSocket.OPEN && socket.bufferedAmount<=131072) socket.send(JSON.stringify({type:'ack',delivery:data.delivery}));
      if(data.type==='signal') {
        const record=this.peers.get(data.from);
        if(!record || data.generation!==record.generation || data.targetGeneration!==this.#generation) return;
        if(record.pendingSignals>=32) {record.media='Signaling backlog exceeded. Restart this guest media.';this.changed();return;}
        record.pendingSignals++;
        record.chain=record.chain.then(()=>{if(epoch===this.#epoch && this.peers.get(record.id)===record)return this.#acceptSignal(data,epoch);})
          .catch(()=>{if(epoch===this.#epoch && this.peers.get(record.id)===record){record.media='Negotiation failed. Restart this guest media.';this.changed();}})
          .finally(()=>{record.pendingSignals--;});
      } else this.#message(data,epoch);
    };
    socket.onclose = event => {
      if(epoch!==this.#epoch) return;
      const terminal = [4000,4001,4003].includes(event.code);
      this.disconnect(terminal);
      this.changed(terminal ? 'Interview ended, expired, revoked or replaced. Reopen a host invite.' : 'Signaling disconnected. Devices stopped; reconnect with the retained in-memory invite.');
    };
    socket.onerror = () => {if(epoch===this.#epoch) this.changed('Signaling failed. Check the host invite and connection.');};
  }
  #message(data,epoch) {
    if(data.type==='welcome') {
      if(data.role!=='host' || !UUID.test(data.id) || !UUID.test(data.generation) || !Number.isFinite(data.expires) || data.expires<=this.api.now()) {
        this.disconnect(true); this.changed('A current host capability is required. Reopen the host invite.'); return;
      }
      this.#id=data.id; this.#generation=data.generation; this.connected=true;
      if(this.#relay) this.#relayTimer=this.api.setTimeout(()=>this.#refreshRelay(epoch),Math.max(0,this.#relay.refreshAt-this.api.now()));
      this.#expiresTimer=this.api.setTimeout(()=>{if(epoch===this.#epoch){this.disconnect(true);this.changed('Host invite expired. Reopen a new invite.');}},Math.min(data.expires-this.api.now(),2147483647));
      this.changed('Reference host connected. Admit a waiting guest to exchange media.'); return;
    }
    if(data.type==='roster' && Array.isArray(data.peers) && data.peers.length<=11) {
      const members = new Map();
      for(const peer of data.peers) if(peer.role==='guest' && UUID.test(peer.id) && typeof peer.name==='string' && peer.name.length<=80 && ['waiting','backstage','onair'].includes(peer.state)) members.set(peer.id,{id:peer.id,name:peer.name,state:peer.state});
      this.members=members;
      for(const [id] of this.peers) if(!members.has(id) || members.get(id).state==='waiting') this.#dropPeer(id);
      this.flags={locked:data.locked===true,program:data.program===true,recording:data.recording===true}; this.changed(); return;
    }
    if(data.type==='admitted' && this.connected && !this.#ending && UUID.test(data.guest) && UUID.test(data.guestGeneration)) {
      const previous=this.peers.get(data.guest);
      if(previous?.generation===data.guestGeneration) return;
      this.#dropPeer(data.guest);
      const record={id:data.guest,generation:data.guestGeneration,negotiation:undefined,pc:undefined,candidates:[],chain:Promise.resolve(),pendingSignals:0,media:'Preparing media',sentICE:0};
      this.peers.set(record.id,record);
      this.#offer(record,epoch).catch(()=>{if(this.peers.get(record.id)===record){record.media='Media unavailable. Configure TURN and restart media.';this.changed();}}); return;
    }
    if(data.type==='ended') { this.disconnect(true); this.changed('Interview ended. Invites cleared and devices stopped.'); return; }
    if(data.type==='error') this.changed('The server refused the requested operation. Check admission and room state.');
  }
  async #relayConfiguration(force=false) {
    const now=this.api.now();
    if(!force && this.#relay && now<this.#relay.refreshAt) return this.#relay.servers;
    if(this.#relayRequest) return this.#relayRequest;
    const epoch=this.#epoch, controller=new AbortController(); this.#relayAbort=controller;
    const timeout=this.api.setTimeout(()=>controller.abort(),8000);
    const request=(async()=>{
      const response=await this.api.fetch(`/v1/rooms/${this.room}/turn`,{method:'POST',headers:{Authorization:`Bearer ${this.#secret}`},signal:controller.signal});
      if(!response.ok) throw new Error('Relay unavailable');
      const data=await response.json();
      if(!Array.isArray(data.iceServers) || data.iceServers.length<1 || data.iceServers.length>8 || !Number.isFinite(data.ttl) || data.ttl<120 || data.ttl>3600) throw new Error('Invalid relay response');
      let hasRelay=false;
      for(const entry of data.iceServers) {
        const urls=typeof entry.urls==='string'?[entry.urls]:entry.urls;
        if(!Array.isArray(urls) || urls.length<1 || urls.length>8 || urls.some(url=>typeof url!=='string' || url.length>512 || !/^(stun|stuns|turn|turns):/.test(url))) throw new Error('Invalid relay URL');
        if(urls.some(url=>/^turns?:/.test(url))) { if(typeof entry.username!=='string' || !entry.username || typeof entry.credential!=='string' || !entry.credential || entry.credential.length>2048) throw new Error('Invalid relay credentials'); hasRelay=true; }
      }
      if(!hasRelay || epoch!==this.#epoch || !this.connected || this.#ending) throw new Error('Stale relay response');
      const lifetime=data.ttl*1000;
      this.#relay={servers:data.iceServers,refreshAt:this.api.now()+lifetime*.8,expiresAt:this.api.now()+lifetime};
      this.api.clearTimeout(this.#relayTimer);
      this.#relayTimer=this.api.setTimeout(()=>this.#refreshRelay(epoch),lifetime*.8);
      return data.iceServers;
    })();
    this.#relayRequest=request;
    try { return await request; } finally {this.api.clearTimeout(timeout);if(this.#relayRequest===request){this.#relayRequest=undefined;this.#relayAbort=undefined;}}
  }
  async #refreshRelay(epoch) {
    if(epoch!==this.#epoch || !this.connected) return;
    try { const servers=await this.#relayConfiguration(true);if(epoch!==this.#epoch)return;for(const record of this.peers.values()) record.pc?.setConfiguration({iceServers:servers});this.changed('Relay credentials refreshed. Long-call behavior remains a test gate.'); }
    catch {if(epoch===this.#epoch){this.changed(this.#relay && this.api.now()>=this.#relay.expiresAt?'Relay credentials expired. Restart media after service recovery.':'Relay refresh failed. Retrying in one minute.');this.#relayTimer=this.api.setTimeout(()=>this.#refreshRelay(epoch),60000);}}
  }
  async #offer(record,epoch) {
    const servers=await this.#relayConfiguration();
    if(epoch!==this.#epoch || this.peers.get(record.id)!==record) return;
    const pc=new this.api.RTCPeerConnection({iceServers:servers});record.pc=pc;record.negotiation=this.api.randomUUID();
    if(this.#local) this.#local.getTracks().forEach(track=>pc.addTrack(track,this.#local));
    else {pc.addTransceiver('audio',{direction:'recvonly'});pc.addTransceiver('video',{direction:'recvonly'});}
    pc.onicecandidate=event=>{
      if(!event.candidate || epoch!==this.#epoch || this.peers.get(record.id)!==record || record.pc!==pc) return;
      if(++record.sentICE>128 || this.#outboundICE.length>=128) {record.media='ICE limit exceeded. Restart media.';this.changed();return;}
      this.#outboundICE.push({record,pc,negotiation:record.negotiation,candidate:event.candidate.toJSON()});if(record.offerSent)this.#drainICE();
    };
    pc.ontrack=event=>{if(this.peers.get(record.id)===record && record.pc===pc){record.stream=event.streams[0]??record.stream??new this.api.MediaStream();if(!record.stream.getTracks().includes(event.track))record.stream.addTrack(event.track);this.changed();}};
    pc.onconnectionstatechange=()=>{if(this.peers.get(record.id)===record && record.pc===pc){record.media=`Media ${pc.connectionState}`;this.changed();}};
    const offer=await pc.createOffer();
    if(epoch!==this.#epoch || this.peers.get(record.id)!==record || record.pc!==pc) return;
    await pc.setLocalDescription(offer);
    if(epoch!==this.#epoch || this.peers.get(record.id)!==record || record.pc!==pc) return;
    if(!this.#signal(record,'offer',{negotiation:record.negotiation,description:pc.localDescription})) throw new Error('Offer unavailable');
    record.offerSent=true;this.#drainICE();
    record.media='Offer sent; waiting for guest answer';this.changed();
  }
  #drainICE() {
    this.#outboundICE=this.#outboundICE.filter(item=>this.peers.get(item.record.id)===item.record && item.record.pc===item.pc && item.record.negotiation===item.negotiation);
    if(this.#iceTimer!==undefined || !this.#outboundICE.some(item=>item.record.offerSent)) return;
    this.#iceTimer=this.api.setTimeout(()=>{
      this.#iceTimer=undefined;const index=this.#outboundICE.findIndex(item=>item.record.offerSent);
      const item=index>=0?this.#outboundICE.splice(index,1)[0]:undefined;
      if(item && this.peers.get(item.record.id)===item.record && item.record.pc===item.pc && item.record.negotiation===item.negotiation && item.record.offerSent) this.#signal(item.record,'candidate',{negotiation:item.negotiation,candidate:item.candidate});
      this.#drainICE();
    },30);
  }
  async #acceptSignal(data,epoch) {
    if(epoch!==this.#epoch || data.targetGeneration!==this.#generation || typeof data.payload!=='string' || byteLength(data.payload)>60000) return;
    const record=this.peers.get(data.from);if(!record || data.generation!==record.generation || !record.pc) return;
    let payload;try{payload=JSON.parse(data.payload);}catch{return;}
    if(!payload || payload.negotiation!==record.negotiation) return;
    const pc=record.pc;
    if(data.kind==='answer' && payload.description?.type==='answer' && typeof payload.description.sdp==='string') {
      await pc.setRemoteDescription(payload.description);if(epoch!==this.#epoch || this.peers.get(record.id)!==record || record.pc!==pc)return;
      const queued=record.candidates;record.candidates=[];
      for(const candidate of queued) {
        if(epoch!==this.#epoch || this.peers.get(record.id)!==record || record.pc!==pc)return;
        try{await pc.addIceCandidate(candidate);}catch{record.media='One remote ICE candidate was rejected';}
      }
      if(epoch===this.#epoch && this.peers.get(record.id)===record && record.pc===pc)this.changed();
    } else if(data.kind==='candidate' && payload.candidate && typeof payload.candidate.candidate==='string' && payload.candidate.candidate.length<=8192) {
      if(pc.remoteDescription){try{await pc.addIceCandidate(payload.candidate);}catch{record.media='One remote ICE candidate was rejected';this.changed();}}
      else if(record.candidates.length<128) record.candidates.push(payload.candidate);
    }
  }
  #dropPeer(id) {
    const record=this.peers.get(id);if(!record)return;
    record.pc?.close();record.stream?.getTracks().forEach(track=>track.stop());record.candidates=[];this.peers.delete(id);
    this.#outboundICE=this.#outboundICE.filter(item=>item.record!==record);
  }
  admit(id) { const member=this.members.get(id);if(member && (member.state==='waiting' || !this.peers.has(id))) this.#send({type:'admit',id}); }
  stage(id) { if(this.members.get(id)?.state==='backstage') this.#send({type:'stage',id}); }
  backstage(id) { if(this.members.get(id)?.state==='onair') this.#send({type:'backstage',id}); }
  revoke(id) { if(this.members.has(id) && this.#send({type:'revoke',id})) {this.#dropPeer(id);this.changed('Guest revocation requested; media stopped locally.');} }
  lock(locked) { this.#send({type:'lock',locked:!!locked}); }
  setStatus(program,recording) { this.#send({type:'status',program:!!program,recording:!!recording}); }
  restartGuest(id) {
    const old=this.peers.get(id);if(!old || !this.connected)return;
    const generation=old.generation;this.#dropPeer(id);
    const record={id,generation,candidates:[],chain:Promise.resolve(),pendingSignals:0,media:'Restarting media',sentICE:0};this.peers.set(id,record);
    this.#offer(record,this.#epoch).catch(()=>{if(this.peers.get(id)===record){record.media='Restart failed. Check TURN availability.';this.changed();}});
  }
  async enableReturn() {
    if(!this.connected || this.#ending || this.#local) return;
    const epoch=++this.#deviceEpoch, connection=this.#epoch;
    let local;try{local=await this.api.mediaDevices.getUserMedia({video:true,audio:{echoCancellation:true,noiseSuppression:true}});
      if(epoch!==this.#deviceEpoch || connection!==this.#epoch || !this.connected){local.getTracks().forEach(track=>track.stop());return;}
      this.#local=local;for(const id of [...this.peers.keys()]) this.restartGuest(id);this.changed('Host camera and microphone return enabled explicitly.');
    }catch{local?.getTracks().forEach(track=>track.stop());if(epoch===this.#deviceEpoch && connection===this.#epoch)this.changed('Return permission denied or devices unavailable. Guest reception remains active.');}
  }
  stopReturn() {++this.#deviceEpoch;this.#local?.getTracks().forEach(track=>track.stop());this.#local=undefined;for(const id of [...this.peers.keys()])this.restartGuest(id);this.changed('Host return stopped. Camera and microphone released.');}
  end() {
    if(this.#ending)return;
    if(!this.#send({type:'end'})){this.disconnect(true);this.changed('Stopped locally. Room end acknowledgement unavailable.');return;}
    this.#ending=true;this.valid=false;this.#secret='';++this.#deviceEpoch;
    for(const id of [...this.peers.keys()])this.#dropPeer(id);
    this.#local?.getTracks().forEach(track=>track.stop());this.#local=undefined;
    this.#relayAbort?.abort();this.#relay=undefined;this.api.clearTimeout(this.#relayTimer);
    this.changed('Ending interview; devices stopped, waiting for server acknowledgement…');
    this.#endTimer=this.api.setTimeout(()=>{this.disconnect(true);this.changed('Stopped locally. Room end acknowledgement unavailable.');},3000);
  }
  leave() {this.disconnect(true);this.changed('Left. Host invite cleared; all devices stopped. Reopen the invite to connect again.');}
  disconnect(wipe=false) {
    const cached=!wipe && this.#relay && this.api.now()<this.#relay.refreshAt ? this.#relay : undefined;
    ++this.#epoch;++this.#deviceEpoch;this.connected=false;this.#ending=false;this.#generation=this.#id=undefined;
    const socket=this.#socket;this.#socket=undefined;socket?.close();
    for(const id of [...this.peers.keys()])this.#dropPeer(id);this.members.clear();
    this.#local?.getTracks().forEach(track=>track.stop());this.#local=undefined;
    this.#relayAbort?.abort();this.#relayAbort=this.#relayRequest=undefined;this.#relay=cached;
    for(const timer of [this.#relayTimer,this.#iceTimer,this.#expiresTimer,this.#endTimer])this.api.clearTimeout(timer);
    this.#relayTimer=this.#iceTimer=this.#expiresTimer=this.#endTimer=undefined;this.#outboundICE=[];
    this.flags={locked:false,program:false,recording:false};if(wipe){this.#secret='';this.valid=false;}this.changed();
  }
}

if(typeof document!=='undefined') {
  const $=id=>document.getElementById(id), cards=new Map();
  const host=new InterviewReferenceHost({onChange:render});
  function render(state) {
    $('status').textContent=state.status;$('connect').disabled=!state.valid||state.connected;
    $('rejoin').disabled=!state.valid;$('leave').disabled=!state.valid;$('end').disabled=!state.connected||state.ending;
    $('room-controls').disabled=!state.connected||state.ending;
    for(const key of ['locked','program','recording'])$(key).checked=state.flags[key];
    $('enable-return').disabled=!state.connected||state.ending||!!state.localStream;$('stop-return').disabled=!state.localStream;
    $('preview').srcObject=state.localStream??null;$('empty').hidden=state.members.size>0;
    for(const [id,card]of cards)if(!state.members.has(id)){card.remove();cards.delete(id);}
    for(const member of state.members.values()) {
      let card=cards.get(member.id);
      if(!card){card=document.createElement('article');const title=document.createElement('h3'),status=document.createElement('p'),video=document.createElement('video');status.className='peer-status';status.setAttribute('role','status');video.autoplay=true;video.playsInline=true;video.muted=true;video.controls=true;video.setAttribute('aria-label','Guest media preview');card.append(title,status,video);
        for(const [label,action]of [['Admit backstage','admit'],['Mark test on air','stage'],['Return backstage','backstage'],['Restart media','restartGuest'],['Revoke invite','revoke']]){const button=document.createElement('button');button.textContent=label;button.dataset.action=action;button.onclick=()=>host[action](member.id);card.append(button);}
        const play=document.createElement('button');play.textContent='Play guest audio';play.dataset.action='play';play.onclick=()=>{video.muted=!video.muted;play.textContent=video.muted?'Play guest audio':'Mute guest audio';if(!video.muted)video.play().catch(()=>host.changed('Use the guest video controls to play audio.'));};card.append(play);cards.set(member.id,card);$('roster').append(card);}
      card.querySelector('h3').textContent=member.name;const peer=state.peers.get(member.id);
      card.querySelector('p').textContent=`${member.state==='onair'?'Test on-air state':member.state} · ${peer?.media??'No media connection'}`;
      const video=card.querySelector('video');if(video.srcObject!==(peer?.stream??null))video.srcObject=peer?.stream??null;
      for(const button of card.querySelectorAll('button')){const action=button.dataset.action;button.disabled=!state.connected||state.ending||(action==='admit'&&member.state!=='waiting'&&!!peer)||(action==='stage'&&member.state!=='backstage')||(action==='backstage'&&member.state!=='onair')||(['restartGuest','play'].includes(action)&&!peer);}
    }
  }
  $('connect').onclick=()=>host.connect();$('rejoin').onclick=()=>host.connect();$('leave').onclick=()=>host.leave();$('end').onclick=()=>host.end();
  $('locked').onchange=()=>host.lock($('locked').checked);$('program').onchange=$('recording').onchange=()=>host.setStatus($('program').checked,$('recording').checked);
  $('enable-return').onclick=()=>host.enableReturn();$('stop-return').onclick=()=>host.stopReturn();
  window.addEventListener('pagehide',()=>host.leave());render(host);
}
