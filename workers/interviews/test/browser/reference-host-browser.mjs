// Actual browser/WebRTC fixture. The loopback server is intentionally a small
// protocol double; the separate workerd tests qualify the real Worker export.
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

const publicPath = fileURLToPath(new URL('../../public/', import.meta.url));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const room = crypto.randomUUID(), hostCap = 'a'.repeat(64), guestCap = 'b'.repeat(64);
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'stream-reference-chrome-'));
const connections = [];
let host, guest, program = false, recording = false, locked = false, ended = false;
let chrome, browser, deadline;

const server = http.createServer(async (request, response) => {
  if (request.method==='POST' && request.url===`/v1/rooms/${room}/turn`) {
    response.setHeader('Content-Type', 'application/json');
    // No live TURN provider: real media uses loopback ICE. Relay lifecycle and
    // expiry use controlled client fixtures rather than an external account.
    response.end(JSON.stringify({ttl:600, iceServers:[
      {urls:'turn:127.0.0.1:9?transport=udp', username:'fixture', credential:'fixture'}
    ]})); return;
  }
  try {
    const name = new URL(request.url, 'http://localhost').pathname;
    assert(/^\/(host|guest)\.(html|js|css)$/.test(name));
    response.setHeader('Content-Type', name.endsWith('js') ? 'application/javascript' : name.endsWith('css') ? 'text/css' : 'text/html');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' wss:; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    response.end(await fs.readFile(path.join(publicPath, name.slice(1))));
  } catch { response.writeHead(404); response.end(); }
});
const wss = new WebSocketServer({noServer:true, handleProtocols:protocols => protocols.has('stream-interview-v1') ? 'stream-interview-v1' : false});
function emit(peer, data) {
  if (peer?.socket.readyState===WebSocket.OPEN) peer.socket.send(JSON.stringify({...data, delivery:++peer.delivery}));
}
function roster() {
  const peers = [host, guest].filter(peer => peer?.socket.readyState===WebSocket.OPEN)
    .map(peer => ({id:peer.id, role:peer.role, name:peer.name, state:peer.state}));
  for (const peer of [host, guest]) emit(peer, {type:'roster', peers, program, recording, locked});
}
server.on('upgrade', (request, socket, head) => {
  const protocols = (request.headers['sec-websocket-protocol'] ?? '').split(',').map(value => value.trim());
  const role = protocols.includes(`cap.${hostCap}`) ? 'host' : protocols.includes(`cap.${guestCap}`) ? 'guest' : null;
  if (!role || ended) {socket.destroy(); return;}
  wss.handleUpgrade(request, socket, head, ws => {
    const previous = role==='host' ? host : guest;
    const peer = {socket:ws, role, id:previous?.id ?? crypto.randomUUID(), generation:crypto.randomUUID(),
      state:'waiting', name:role==='host' ? 'Host' : 'Guest', delivery:0};
    if (role==='host') host = peer; else guest = peer;
    connections.push(peer); previous?.socket.close(4001, 'Replaced');
    emit(peer, {type:'welcome', id:peer.id, role, generation:peer.generation, expires:Date.now()+7200000}); roster();
    ws.on('message', raw => {
      const data = JSON.parse(raw);
      if (data.type==='ack') return;
      if (data.type==='hello') {peer.name = data.name; roster(); return;}
      if (data.type==='signal') {
        const target = role==='host' ? guest : host;
        if (target && data.to===target.id && data.targetGeneration===target.generation && guest?.state!=='waiting')
          emit(target, {type:'signal', from:peer.id, generation:peer.generation, targetGeneration:target.generation, kind:data.kind, payload:data.payload});
        return;
      }
      if (role!=='host') return;
      if (['admit','stage','backstage'].includes(data.type) && guest && data.id===guest.id) {
        if (data.type==='stage' && guest.state==='waiting') return;
        guest.state = data.type==='stage' ? 'onair' : 'backstage';
        emit(guest, {type:'admitted', host:peer.id, hostGeneration:peer.generation, state:guest.state});
        emit(peer, {type:'admitted', guest:guest.id, guestGeneration:guest.generation, state:guest.state}); roster(); return;
      }
      if (data.type==='revoke' && data.id===guest?.id) {const old = guest; guest = undefined; old?.socket.close(4003, 'Revoked'); roster(); return;}
      if (data.type==='lock') {locked = data.locked; roster(); return;}
      if (data.type==='status') {program = data.program; recording = data.recording; roster(); return;}
      if (data.type==='end') {ended = true; for (const item of [host, guest]) {emit(item, {type:'ended'}); item?.socket.close(4000, 'Ended');}}
    });
    ws.on('close', () => {
      if (role==='host' && host===peer) {
        host = undefined; program = recording = false;
        if (guest) {guest.state = 'waiting'; emit(guest, {type:'host-disconnected'});}
      }
      if (role==='guest' && guest===peer) guest = undefined;
      roster();
    });
  });
});

class CDP {
  constructor(socket) {
    this.socket = socket; this.id = 0; this.pending = new Map(); this.errors = [];
    socket.on('message', raw => {
      const message = JSON.parse(raw), pending = this.pending.get(message.id);
      if (pending) {clearTimeout(pending.timeout); this.pending.delete(message.id);
        message.error ? pending.reject(new Error(message.error.message)) : pending.resolve(message.result);}
      if (message.method==='Runtime.exceptionThrown') this.errors.push(message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text);
    });
    socket.on('close', () => {
      for (const pending of this.pending.values()) {clearTimeout(pending.timeout); pending.reject(new Error('Chrome connection closed'));}
      this.pending.clear();
    });
  }
  send(method, params={}, sessionId) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {this.pending.delete(id); reject(new Error(`Chrome timeout: ${method}`));}, 10000);
      this.pending.set(id, {resolve, reject, timeout});
      this.socket.send(JSON.stringify({id, method, params, sessionId}), error => {
        if (error) {clearTimeout(timeout); this.pending.delete(id); reject(error);}
      });
    });
  }
  async target(url) {
    const target = await this.send('Target.createTarget', {url:'about:blank'});
    const attached = await this.send('Target.attachToTarget', {targetId:target.targetId, flatten:true});
    await this.send('Page.enable', {}, attached.sessionId); await this.send('Runtime.enable', {}, attached.sessionId);
    await this.send('Page.navigate', {url}, attached.sessionId); return attached.sessionId;
  }
  async evaluate(session, expression) {
    const result = await this.send('Runtime.evaluate', {expression, returnByValue:true, awaitPromise:true, userGesture:true}, session);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  }
  async wait(session, expression, label) {
    for (let attempt=0; attempt<200; attempt++) {if (await this.evaluate(session, expression)) return; await pause(100);}
    throw new Error(`Timeout: ${label}; status=${await this.evaluate(session, "document.getElementById('status')?.textContent")}`);
  }
}
async function chromePath() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;
  const names = process.platform==='darwin' ? ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'] :
    (process.env.PATH ?? '').split(path.delimiter).flatMap(directory => ['google-chrome','google-chrome-stable','chromium','chromium-browser','chrome'].map(name => path.join(directory, name)));
  for (const name of names) {try {await fs.access(name); return name;} catch {}}
  throw new Error('Install Chrome/Chromium or set CHROME_BIN to its executable path.');
}
async function run() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  chrome = spawn(await chromePath(), ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-component-update',
    '--disable-sync', '--disable-extensions', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream',
    '--autoplay-policy=no-user-gesture-required',
    ...(process.env.CHROME_NO_SANDBOX==='1' ? ['--no-sandbox'] : []), 'about:blank'], {stdio:'ignore'});
  let launchError; chrome.on('error', error => {launchError = error;});
  let lines;
  for (let attempt=0; attempt<100; attempt++) {
    if (launchError) throw launchError;
    try {lines = (await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).trim().split('\n'); break;} catch {await pause(100);}
  }
  if (!lines) throw new Error('Chrome did not open its local debugging endpoint.');
  const socket = new WebSocket(`ws://127.0.0.1:${lines[0]}${lines[1]}`, {handshakeTimeout:10000});
  await new Promise((resolve, reject) => {socket.once('open', resolve); socket.once('error', reject);});
  browser = new CDP(socket);
  const h = await browser.target(`${origin}/host.html?room=${room}#${hostCap}`);
  const g = await browser.target(`${origin}/guest.html?room=${room}#${guestCap}`);
  await browser.wait(h, "typeof document.getElementById('connect')?.onclick==='function'", 'host page');
  await browser.wait(g, "typeof document.getElementById('prepare')?.onclick==='function'", 'guest page');
  assert.equal(await browser.evaluate(h, 'location.hash'), ''); assert.equal(await browser.evaluate(g, 'location.hash'), '');
  await browser.evaluate(h, "document.getElementById('connect').click()");
  await browser.wait(h, "document.getElementById('status').textContent.includes('connected')", 'host signaling');
  await browser.evaluate(g, "document.getElementById('prepare').click()");
  await browser.wait(g, "!document.getElementById('join').disabled", 'synthetic guest devices');
  await browser.evaluate(g, "window.__fixtureGuestTracks=document.getElementById('preview').srcObject.getTracks(); document.getElementById('join').click()");
  await browser.wait(h, "document.querySelector('[data-action=admit]')", 'waiting guest');
  await browser.evaluate(h, "document.querySelector('[data-action=admit]').click()");
  await browser.wait(h, "document.querySelector('#roster video')?.videoWidth>0 && document.querySelector('#roster video')?.srcObject?.getTracks().some(t=>t.kind==='audio'&&t.readyState==='live')", 'real guest video/audio tracks');
  assert.equal(await browser.evaluate(g, "document.getElementById('return').srcObject"), null);
  await browser.evaluate(h, "document.getElementById('enable-return').click()");
  await browser.wait(g, "document.getElementById('return').videoWidth>0", 'real optional host return');
  await browser.evaluate(h, "window.__fixtureHostTracks=document.getElementById('preview').srcObject.getTracks(); document.querySelector('[data-action=stage]').click()");
  await browser.wait(h, "document.querySelector('.peer-status').textContent.includes('Test on-air')", 'authoritative test stage');
  await browser.evaluate(h, "document.getElementById('program').click(); document.getElementById('recording').click()");
  await browser.wait(g, "document.getElementById('program').textContent.includes('Program live')&&document.getElementById('program').textContent.includes('Recording active')", 'authoritative protocol status flags');
  await browser.evaluate(g, "document.getElementById('rejoin').click()");
  await browser.wait(h, "document.querySelector('[data-action=admit]')&&!document.querySelector('[data-action=admit]').disabled", 'guest rejoin waiting');
  await browser.evaluate(h, "document.querySelector('[data-action=admit]').click()");
  await browser.wait(h, "document.querySelector('#roster video')?.videoWidth>0&&document.querySelector('#roster video')?.srcObject?.getTracks().some(t=>t.readyState==='live')", 'guest media after readmission');
  // Genuine host loss must release return devices and require a new admission.
  await browser.evaluate(h, "document.getElementById('rejoin').click()");
  await browser.wait(h, "window.__fixtureHostTracks.every(t=>t.readyState==='ended')&&document.getElementById('preview').srcObject===null", 'host devices stopped on reconnect');
  await browser.wait(h, "!document.querySelector('[data-action=admit]').disabled", 'host rejoin waiting roster');
  await browser.evaluate(h, "document.querySelector('[data-action=admit]').click()");
  await browser.wait(h, "document.querySelector('#roster video')?.videoWidth>0&&document.querySelector('#roster video')?.srcObject?.getTracks().some(t=>t.readyState==='live')", 'guest media after host rejoin');
  await browser.evaluate(h, "document.getElementById('enable-return').click()");
  await browser.wait(h, "document.getElementById('preview').srcObject!==null", 'new explicit host return');
  await browser.evaluate(h, "window.__fixtureHostTracks=document.getElementById('preview').srcObject.getTracks(); document.querySelector('[data-action=revoke]').click()");
  await browser.wait(g, "document.getElementById('prepare').disabled&&document.getElementById('preview').srcObject===null&&document.getElementById('return').srcObject===null&&window.__fixtureGuestTracks.every(t=>t.readyState==='ended')", 'revoke stops guest tracks and invite');
  await browser.evaluate(h, "document.getElementById('end').click()");
  await browser.wait(h, "document.getElementById('preview').srcObject===null&&document.getElementById('connect').disabled&&window.__fixtureHostTracks.every(t=>t.readyState==='ended')", 'end stops host tracks and invite');
  assert.deepEqual(browser.errors, []);
  console.log('PASS actual headless Chrome: fragment wipe, explicit admission, real synthetic WebRTC video/audio tracks, optional host return, authoritative test stage, guest/host reconnect and readmission, revoke/end track and capability cleanup. Loopback fixture; no real TURN or native/physical qualification.');
}
try {
  await Promise.race([run(), new Promise((_resolve, reject) => {deadline = setTimeout(() => reject(new Error('Browser fixture exceeded 120 seconds')), 120000);})]);
} finally {
  clearTimeout(deadline); browser?.socket.close(); chrome?.kill('SIGTERM');
  for (const peer of connections) peer.socket.terminate(); wss.close(); server.closeAllConnections();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  if (chrome?.pid && chrome.exitCode===null && chrome.signalCode===null) {
    let terminateDeadline;
    try {
      await new Promise((resolve, reject) => {
        chrome.once('exit', resolve);
        terminateDeadline = setTimeout(() => {
          chrome.kill('SIGKILL');
          // Wait for the exit event after escalation before deleting its profile.
          terminateDeadline = setTimeout(() => reject(new Error('Chrome did not exit during fixture cleanup')), 2000);
        }, 2000);
      });
    } finally { clearTimeout(terminateDeadline); }
  }
  // Chrome helpers can finish profile writes just after the browser exits.
  // Retry only Node's transient recursive-removal errors, with a bounded delay.
  await fs.rm(profile, {recursive:true, force:true, maxRetries:10, retryDelay:100});
}
