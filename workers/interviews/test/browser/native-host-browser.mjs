// Actual Chrome -> app-owned native host transport/codec fixture. The local
// signaling double is separate from the Worker tests. No operator devices.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {WebSocket, WebSocketServer} from 'ws';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const publicPath = fileURLToPath(new URL('../../public/', import.meta.url));
const room = crypto.randomUUID(), hostID = crypto.randomUUID(), guestID = crypto.randomUUID();
const capability = 'b'.repeat(64), hostGeneration = crypto.randomUUID();
const media = {audio:'audio-mid', camera:'camera-mid', screen:'screen-mid'};
const cli = process.env.NATIVE_GUEST_HOST;
assert(cli && path.isAbsolute(cli), 'Set NATIVE_GUEST_HOST to the absolute native host CLI binary path');
await fs.access(cli, fs.constants.X_OK);

async function wait(label, predicate, timeout = 15_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const value = await predicate(); if (value) return value; await pause(50); }
  throw new Error(`Bounded fixture timeout: ${label}`);
}

class NativeHost {
  constructor(generation, negotiation) {
    this.generation = generation; this.negotiation = negotiation; this.ready = false;
    this.stopped = false; this.exited = false; this.failure = undefined; this.offer = undefined;
    this.controlClosed = false; this.expectControlClose = false;
    this.candidates = []; this.controls = []; this.mapping = undefined; this.lines = 0;
    this.roles = Object.fromEntries(['camera','screen','audio'].map(role => [role, {count:0, frames:0, headerExtensions:0, first:undefined, last:undefined, peak:[0,0], rgb:undefined}]));
    this.process = spawn(cli, [], {stdio:['pipe','pipe','pipe']});
    this.process.on('error', () => { this.failure = new Error('Native host process could not launch'); });
    this.process.stdin.on('error', () => { this.failure = new Error('Native host command pipe closed'); });
    // close follows stdio drainage; exit can precede the final stopped line.
    this.process.on('close', (code, signal) => {
      this.exited = true;
      if (!this.stopped) this.failure = new Error(`Native host exited before stopped receipt (code=${code}, signal=${signal})`);
      else if (code !== 0 || signal) this.failure = new Error(`Native host exited unsuccessfully (code=${code}, signal=${signal})`);
    });
    let pending = '', stderrBytes = 0;
    this.process.stderr.on('data', chunk => {
      // Never mirror arbitrary CLI diagnostics/SDP to the test log.
      stderrBytes += chunk.length;
      if (stderrBytes > 262_144) this.failure = new Error('Native host diagnostic byte budget exceeded');
    });
    this.process.stdout.on('data', chunk => {
      if (this.failure) return;
      if (pending.length + chunk.length > 196_608) { this.failure = new Error('Native JSON-lines receive budget exceeded'); this.kill(); return; }
      pending += chunk.toString('utf8');
      let newline;
      while ((newline = pending.indexOf('\n')) !== -1) {
        const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
        let value;
        try { assert(line.length <= 98_304); if (line.trim()) { value = JSON.parse(line); this.receive(value); } }
        catch (error) {
          const type = ['offer','candidate','ready','control','control-state','decoded','stopped','error'].includes(value?.type) ? value.type : 'unknown';
          const detail = String(error.message).split('\n')[0].slice(0,160);
          this.failure = new Error(`Native protocol receipt rejected (type=${type}): ${detail}`);
        }
      }
    });
  }
  check() { if (this.failure) throw this.failure; }
  send(value) {
    this.check(); assert(!this.exited, 'Native host process is unavailable');
    const line = JSON.stringify({...value, generation:this.generation, negotiation:this.negotiation}) + '\n';
    assert(Buffer.byteLength(line) <= 98_304 && this.process.stdin.writableLength < 196_608, 'Native command backlog exceeded');
    this.process.stdin.write(line, error => { if (error) this.failure = new Error('Native host command pipe closed'); });
  }
  receive(value) {
    this.lines++;
    assert(value && value.generation === this.generation && value.negotiation === this.negotiation, 'Native generation/negotiation mismatch');
    assert(!this.stopped, 'Native host emitted after stopped receipt');
    if (value.type === 'offer') {
      assert(!this.offer && value.description?.type === 'offer' && typeof value.description.sdp === 'string');
      assert(value.description.sdp.length <= 65_536); assert.deepEqual(value.media, media);
      this.offer = value; this.onSignal?.('offer', value); return;
    }
    if (value.type === 'candidate') {
      assert(typeof value.candidate?.candidate === 'string' && value.candidate.candidate.length <= 4096);
      assert(typeof value.candidate.sdpMid === 'string' && value.candidate.sdpMid.length <= 64);
      if (this.onSignal) this.onSignal('candidate', value);
      else { assert(this.candidates.length < 128); this.candidates.push(value); } return;
    }
    if (value.type === 'ready') { this.ready = true; return; }
    if (value.type === 'control') {
      assert(value.message?.type === 'screen-state' && value.message.negotiation === this.negotiation && typeof value.message.sharing === 'boolean');
      this.controls.push(value.message); if (this.controls.length > 32) this.controls.shift(); return;
    }
    if (value.type === 'control-state') {
      assert.equal(value.state,'closed');
      assert(this.expectControlClose,'Native control channel closed before the explicit guest Leave boundary');
      this.controlClosed = true; return;
    }
    if (value.type === 'decoded') {
      const state = this.roles[value.role]; assert(state);
      assert(Number.isFinite(value.pts) && /^[0-9a-f-]{36}$/i.test(value.mappingGeneration));
      assert.equal(value.clockQuality, 'senderReportAligned');
      assert(Number.isSafeInteger(value.headerExtensions)&&value.headerExtensions>=state.headerExtensions,'Native RTP header-extension counter must be monotonic');
      state.headerExtensions = value.headerExtensions;
      this.mapping ??= value.mappingGeneration; assert.equal(value.mappingGeneration, this.mapping);
      assert(state.last === undefined || value.pts >= state.last, 'Decoded timestamps must be monotonic per source');
      state.first ??= value.pts; state.last = value.pts; state.count++;
      if (value.role === 'audio') {
        assert.equal(value.channels, 2); assert.equal(value.sampleRate, 48_000);
        assert(Number.isInteger(value.frames) && value.frames > 0 && value.frames <= 5760);
        assert(Number.isFinite(value.duration) && Math.abs(value.duration - value.frames / 48_000) < 0.000001);
        assert(Array.isArray(value.rms) && value.rms.length === 2 && value.rms.every(n => Number.isFinite(n) && n >= 0 && n <= 1));
        state.frames += value.frames; state.peak = state.peak.map((n, i) => Math.max(n, value.rms[i]));
      } else {
        assert.equal(value.width, 320); assert.equal(value.height, 180);
        assert(Array.isArray(value.centerRGB) && value.centerRGB.length === 3 && value.centerRGB.every(n => Number.isFinite(n) && n >= 0 && n <= 255));
        state.rgb = value.centerRGB;
      } return;
    }
    if (value.type === 'stopped') { this.stopped = true; return; }
    if (value.type === 'error') {
      const reason = typeof value.reason === 'string' && /^[a-z0-9-]{1,64}$/.test(value.reason) ? value.reason : 'unknown';
      throw new Error(`Native host error: ${reason}`);
    }
    throw new Error('Unknown native host receipt');
  }
  attach(send) {
    this.onSignal = send;
    if (this.offer) send('offer', this.offer);
    for (const candidate of this.candidates) send('candidate', candidate);
    this.candidates = [];
  }
  async stop() {
    this.onSignal = undefined;
    if (!this.stopped && !this.exited) this.send({type:'stop'});
    await wait('native source gate/destroy stopped receipt', () => { this.check(); return this.stopped; }, 10_000);
    this.process.stdin.end();
    await wait('no late native output and process exit', () => { this.check(); return this.exited; }, 5000);
  }
  kill() { this.process.kill('SIGKILL'); }
}

class CDP {
  constructor(socket) {
    this.socket = socket; this.id = 0; this.pending = new Map(); this.errors = [];
    socket.on('message', raw => {
      const value = JSON.parse(raw), pending = this.pending.get(value.id);
      if (pending) { this.pending.delete(value.id); clearTimeout(pending.timer);
        value.error ? pending.reject(new Error(value.error.message)) : pending.resolve(value.result); }
      if (value.method === 'Runtime.exceptionThrown') this.errors.push(value.params.exceptionDetails.text);
    });
    socket.on('close', () => { for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('Chrome closed')); } this.pending.clear(); });
  }
  send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      const id = ++this.id, timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Chrome timeout: ${method}`)); }, 10_000);
      this.pending.set(id, {resolve,reject,timer}); this.socket.send(JSON.stringify({id,method,params,sessionId}));
    });
  }
  async evaluate(sessionId, expression) {
    const result = await this.send('Runtime.evaluate', {expression,returnByValue:true,awaitPromise:true,userGesture:true}, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  }
  async until(sessionId, expression, label) { return wait(label, () => this.evaluate(sessionId, expression)); }
}

// Real generated tracks. These overrides replace only operator capture APIs;
// the app's guest page, RTCPeerConnection, codecs, SRTP and decoder stay real.
const syntheticMedia = `
window.__fixturePeers=[];window.__fixtureCamera=[];window.__fixtureScreens=[];window.__fixtureAudio=[];
const Peer=window.RTCPeerConnection;window.RTCPeerConnection=class extends Peer{constructor(...args){super(...args);window.__fixturePeers.push(this);}};
const canvasTrack=color=>{const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;const context=canvas.getContext('2d');let counter=0;
const paint=()=>{context.fillStyle=color;context.fillRect(0,0,320,180);context.fillStyle='white';context.fillRect((counter++%80)*4,0,4,4);};paint();
const stream=canvas.captureStream(15),track=stream.getVideoTracks()[0];const timer=setInterval(()=>{if(track.readyState==='ended'){clearInterval(timer);return;}paint();},60);return stream;};
Object.defineProperty(navigator.mediaDevices,'enumerateDevices',{value:async()=>[]});
Object.defineProperty(navigator.mediaDevices,'getUserMedia',{value:async()=>{const camera=canvasTrack('rgb(220,20,15)');window.__fixtureCamera.push(camera);
const context=new AudioContext({sampleRate:48000});await context.resume();const destination=context.createMediaStreamDestination(),merge=context.createChannelMerger(2);
for(const [channel,frequency]of [[0,440],[1,880]]){const oscillator=context.createOscillator(),gain=context.createGain();oscillator.frequency.value=frequency;gain.gain.value=channel===0?.14:.07;oscillator.connect(gain).connect(merge,0,channel);oscillator.start();}
merge.connect(destination);window.__fixtureAudio.push({context,stream:destination.stream});destination.stream.getTracks()[0].addEventListener('ended',()=>context.close());return new MediaStream([...camera.getTracks(),...destination.stream.getTracks()]);}});
Object.defineProperty(navigator.mediaDevices,'getDisplayMedia',{value:async()=>{const stream=canvasTrack('rgb(15,20,220)');window.__fixtureScreens.push(stream);return stream;}});
`;

let peer, native, chrome, browserSocket, browser, serverFailure;
const hosts = [], profile = await fs.mkdtemp(path.join(os.tmpdir(), 'stream-native-host-chrome-'));
const server = http.createServer(async (request, response) => {
  try {
    if (request.method === 'POST' && request.url === `/v1/rooms/${room}/turn`) {
      assert.equal(request.headers.authorization, `Bearer ${capability}`);
      response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ttl:600,iceServers:[]})); return;
    }
    const name = new URL(request.url, 'http://localhost').pathname;
    assert(/^\/guest\.(html|js|css)$/.test(name));
    response.setHeader('Content-Type', name.endsWith('.js') ? 'application/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html');
    response.setHeader('Referrer-Policy', 'no-referrer'); response.end(await fs.readFile(path.join(publicPath, name.slice(1))));
  } catch { response.writeHead(404); response.end(); }
});
const wss = new WebSocketServer({noServer:true,handleProtocols:protocols => protocols.has('stream-interview-v1') ? 'stream-interview-v1' : false});
const emit = value => {
  if (peer?.socket.readyState !== WebSocket.OPEN) return;
  if (peer.socket.bufferedAmount > 196_608) { serverFailure = new Error('Fixture signaling backlog exceeded'); peer.socket.close(1008,'Backlog'); return; }
  peer.socket.send(JSON.stringify({...value,delivery:++peer.delivery}));
};
function relay(kind, value) {
  const payload = kind === 'offer' ? {negotiation:value.negotiation,description:value.description,media:value.media} : {negotiation:value.negotiation,candidate:value.candidate};
  emit({type:'signal',from:hostID,generation:hostGeneration,targetGeneration:peer.generation,kind,payload:JSON.stringify(payload)});
}
function admit() {
  assert(peer && native); peer.admitted = true;
  emit({type:'admitted',host:hostID,hostGeneration,state:'backstage'});
  native.attach(relay);
}
server.on('upgrade', (request, socket, head) => {
  const protocols = (request.headers['sec-websocket-protocol'] ?? '').split(',').map(value => value.trim());
  if (!protocols.includes(`cap.${capability}`)) { socket.destroy(); return; }
  wss.handleUpgrade(request,socket,head,ws => {
    const previous = peer; peer = {socket:ws,generation:crypto.randomUUID(),delivery:0,admitted:false}; previous?.socket.close(4001,'Replaced');
    const current = peer;
    emit({type:'welcome',id:guestID,role:'guest',generation:peer.generation,expires:Date.now()+60_000});
    ws.on('message', raw => {
      try {
        if (peer !== current) return;
        assert(raw.length <= 98_304); const value = JSON.parse(raw);
        if (value.type === 'hello' || value.type === 'ack') return;
        assert(value.type === 'signal');
        if (!current.admitted || native?.stopped || native?.exited) return;
        assert(value.to === hostID && value.targetGeneration === hostGeneration);
        assert(typeof value.payload === 'string' && value.payload.length <= 98_304); const payload = JSON.parse(value.payload);
        if (payload.negotiation !== native.negotiation) return;
        if (value.kind === 'answer') native.send({type:'answer',description:payload.description});
        else if (value.kind === 'candidate') native.send({type:'candidate',candidate:payload.candidate});
        else throw new Error('Unexpected guest signal kind');
      } catch { serverFailure = new Error('Guest signaling contract failed'); }
    });
  });
});

async function newHost(generation) {
  native = new NativeHost(generation,crypto.randomUUID()); hosts.push(native);
  native.send({type:'start',media});
  await wait('native host-generated SDP offer', () => { native.check(); return native.offer; });
  return native;
}
const check = () => { assert(!serverFailure, serverFailure?.message); native?.check(); };

try {
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const executable = process.env.CHROME_BIN ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  chrome = spawn(executable,['--headless=new','--remote-debugging-port=0',`--user-data-dir=${profile}`,'--no-first-run',
    '--disable-background-networking','--disable-component-update','--disable-extensions','--autoplay-policy=no-user-gesture-required',
    ...(process.env.CHROME_NO_SANDBOX === '1' ? ['--no-sandbox'] : []),'about:blank'],{stdio:'ignore'});
  let launchFailure; chrome.on('error', () => { launchFailure = true; });
  const port = await wait('isolated Chrome launch', async () => {
    assert(!launchFailure, 'Chrome launch failed');
    try { return (await fs.readFile(path.join(profile,'DevToolsActivePort'),'utf8')).trim().split('\n'); } catch { return undefined; }
  });
  browserSocket = new WebSocket(`ws://127.0.0.1:${port[0]}${port[1]}`,{handshakeTimeout:10_000});
  await new Promise((resolve,reject) => { browserSocket.once('open',resolve); browserSocket.once('error',reject); });
  browser = new CDP(browserSocket); const version = await browser.send('Browser.getVersion');
  const target = await browser.send('Target.createTarget',{url:'about:blank'});
  const {sessionId:g} = await browser.send('Target.attachToTarget',{targetId:target.targetId,flatten:true});
  await browser.send('Page.enable',{},g); await browser.send('Runtime.enable',{},g);
  await browser.send('Page.addScriptToEvaluateOnNewDocument',{source:syntheticMedia},g);
  await browser.send('Page.navigate',{url:`${origin}/guest.html?room=${room}#${capability}`},g);
  await browser.until(g,"typeof document.getElementById('prepare').onclick==='function'",'actual guest page');
  assert.equal(await browser.evaluate(g,'location.hash'),'');
  await browser.evaluate(g,"document.getElementById('prepare').click()");
  await browser.until(g,"!document.getElementById('join').disabled",'synthetic camera/tone prepared');
  await browser.evaluate(g,"document.getElementById('join').click()");
  await wait('waiting room socket',()=>peer);
  assert.equal(await browser.evaluate(g,"window.__fixturePeers.length"),0,'No media peer before admission');
  const first = await newHost(7); admit();
  await wait('actual native DTLS/control open',()=>{check();return first.ready;});
  await wait('native H264 camera + stereo Opus PCM decoded',()=>{check();return first.roles.camera.count>=4&&first.roles.audio.frames>=4800;});
  const rgb = first.roles.camera.rgb; assert(rgb[0]>150&&rgb[1]<80&&rgb[2]<80);
  assert(first.roles.audio.peak.every(value=>value>.01),'Actual native decoded audio must contain the synthetic tone');
  const stereoRatio = first.roles.audio.peak[0] / first.roles.audio.peak[1];
  assert(stereoRatio>1.3&&stereoRatio<3,'Native PCM must retain the independently generated stereo channels');
  assert(first.roles.camera.headerExtensions>0&&first.roles.audio.headerExtensions>0,'Actual Chrome camera/audio RTP must exercise negotiated MID header extensions');
  assert.equal(first.roles.screen.count,0); assert.equal(await browser.evaluate(g,"document.getElementById('share').disabled"),true);
  console.log(`PASS ${version.product}: shipping guest answers native host offer; actual H264 pixels/stereo48k Opus PCM decode before screen approval`);

  first.send({type:'approval',approved:true});
  await browser.until(g,"!document.getElementById('share').disabled",'explicit native host approval');
  const concurrent = {camera:first.roles.camera.count,audio:first.roles.audio.frames};
  await browser.evaluate(g,"document.getElementById('share').click()");
  await wait('native simultaneous camera/screen/audio decoded',()=>{check();return first.roles.screen.count>=3&&first.controls.some(value=>value.sharing)
    &&first.roles.camera.count>concurrent.camera+2&&first.roles.audio.frames>concurrent.audio+1920;});
  assert(first.roles.screen.rgb[2]>150&&first.roles.screen.rgb[0]<80);
  assert(first.roles.screen.headerExtensions>0,'Actual Chrome screen RTP must exercise negotiated MID header extensions');
  const mids = await browser.evaluate(g,"window.__fixturePeers.at(-1).getTransceivers().map(t=>t.mid)");
  assert(mids.includes(media.camera)&&mids.includes(media.screen)&&new Set(mids).size===3);
  const before = {camera:first.roles.camera.count,audio:first.roles.audio.frames};
  await browser.evaluate(g,"document.getElementById('stopshare').click()");
  await wait('native screen-state stop acknowledgment',()=>{check();return first.controls.at(-1)?.sharing===false;});
  await browser.until(g,"window.__fixtureScreens.every(s=>s.getTracks().every(t=>t.readyState==='ended'))&&document.getElementById('preview').srcObject.getTracks().every(t=>t.readyState==='live')",'screen-only capture stop');
  await wait('camera/audio remain natively decoded after screen stop',()=>{check();return first.roles.camera.count>before.camera+2&&first.roles.audio.frames>before.audio+1920;});
  first.send({type:'approval',approved:false});
  await browser.until(g,"document.getElementById('share').disabled",'native grant removed');
  console.log('PASS native approval data channel: distinct camera/screen MIDs and pixels; screen-only stop preserves decoded camera/audio');

  // Replacement keeps stable guest source identities but invalidates the old
  // negotiation and its grants. Old native handles must finish first.
  const oldNegotiation = first.negotiation; await first.stop();
  const oldSocket = peer;
  await browser.evaluate(g,"document.getElementById('rejoin').click()");
  await wait('replacement guest socket generation',()=>peer!==oldSocket);
  const second = await newHost(8); assert.notEqual(second.negotiation,oldNegotiation); admit();
  await wait('replacement native host ready and media',()=>{check();return second.ready&&second.roles.camera.count>=3&&second.roles.audio.frames>=2880;});
  assert.equal(await browser.evaluate(g,"document.getElementById('share').disabled"),true);
  assert.equal(second.roles.screen.count,0,'Replacement cannot inherit a screen grant');
  await browser.until(g,"window.__fixturePeers.slice(0,-1).every(p=>p.connectionState==='closed')",'old guest peer closed');
  second.send({type:'approval',approved:true});
  await browser.until(g,"!document.getElementById('share').disabled",'replacement explicit grant');
  await browser.evaluate(g,"document.getElementById('share').click()");
  await wait('replacement screen decodes on fresh native lease',()=>{check();return second.roles.screen.count>=2;});
  second.expectControlClose = true;
  await browser.evaluate(g,"document.getElementById('leave').click()");
  await browser.until(g,"document.getElementById('preview').srcObject===null&&document.getElementById('prepare').disabled&&window.__fixtureCamera.every(s=>s.getTracks().every(t=>t.readyState==='ended'))&&window.__fixtureScreens.every(s=>s.getTracks().every(t=>t.readyState==='ended'))",'terminal guest capture cleanup');
  await wait('native observes explicit guest control closure',()=>{check();return second.controlClosed;});
  await second.stop(); check(); assert.deepEqual(browser.errors,[]);
  console.log('PASS native reconnect/stop: fresh generation/negotiation, grants reset, old peer closed, terminal tracks stopped, no decoded receipt after native stopped');
  console.log('Scope: synthetic canvas/AudioContext capture APIs; real Chrome offer/answer, ICE/DTLS/SRTP, H264/Opus RTP and native decoded receipts. Loopback signaling double; no engine, Program, mix-minus, TURN, physical-device or production-service qualification.');
} finally {
  for (const host of hosts) if (!host.exited) host.kill();
  browserSocket?.close();
  if (chrome && chrome.exitCode === null) { chrome.kill('SIGTERM'); await Promise.race([new Promise(resolve=>chrome.once('exit',resolve)),pause(2000)]); if (chrome.exitCode===null) chrome.kill('SIGKILL'); }
  for (const client of wss.clients) client.terminate(); wss.close();
  await new Promise(resolve=>server.close(resolve));
  await fs.rm(profile,{recursive:true,force:true});
}
