import { DurableObject } from 'cloudflare:workers';

type Role = 'host' | 'guest';
type Membership = 'waiting' | 'backstage' | 'onair';
type Peer = { id: string; role: Role; hash: string; name: string; state: Membership; generation: string; window: number; count: number; ackCount: number; deliveries: number[]; nextDelivery: number };
type Invite = { id: string; hash: string; role: Role; expires: number; revoked: number };
type Room = { expires: number; capacity: number; locked: boolean; ended: boolean; program: boolean; recording: boolean };
const protocol = 'stream-interview-v1';
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: { 'Cache-Control': 'no-store' } });
const fail = (status: number, error: string) => json({ error }, status);
const hex = (bytes: Uint8Array) => [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
const token = () => hex(crypto.getRandomValues(new Uint8Array(32)));
const digest = async (value: string) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))));
async function authorized(request: Request, secret: string | undefined) {
  if (!secret) return false;
  const incoming = request.headers.get('Authorization')?.replace(/^Bearer /, '') ?? '';
  if (incoming.length > 1024) return false;
  const bytes = (value: string) => new TextEncoder().encode(value);
  return crypto.subtle.timingSafeEqual(bytes(await digest(incoming)), bytes(await digest(secret)));
}
async function body(request: Request | Response): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  if (!reader) throw new Error('Missing body');
  let size = 0; const chunks: Uint8Array[] = [];
  try {
    for (;;) {
      const item = await reader.read(); if (item.done) break;
      size += item.value.length; if (size > 8192) throw new Error('Body too large'); chunks.push(item.value);
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  const data = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
  const parsed: unknown = JSON.parse(new TextDecoder().decode(data));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Expected object');
  return parsed as Record<string, unknown>;
}
function relayConfiguration(data: Record<string, unknown>) {
  if (!Array.isArray(data.iceServers) || data.iceServers.length < 1 || data.iceServers.length > 8) throw new Error('Invalid ICE servers');
  let relay = false;
  const iceServers = data.iceServers.map(value => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid ICE server');
    const entry = value as Record<string, unknown>;
    const urls = typeof entry.urls === 'string' ? [entry.urls] : entry.urls;
    if (!Array.isArray(urls) || urls.length < 1 || urls.length > 8) throw new Error('Invalid ICE URLs');
    const accepted = urls.filter(url => {
      if (typeof url !== 'string' || url.length > 512 || !/^(?:stun|stuns|turn|turns):[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:\?transport=(?:udp|tcp))?$/.test(url)) throw new Error('Invalid ICE URL');
      const port = /:([0-9]+)(?:\?|$)/.exec(url)?.[1];
      if (port && (Number(port) < 1 || Number(port) > 65535)) throw new Error('Invalid ICE port');
      // Browsers block the alternate DNS port; retain usable provider URLs.
      return !/:53(?:\?|$)/.test(url);
    });
    if (accepted.some(url => /^turns?:/.test(url))) {
      if (typeof entry.username !== 'string' || !entry.username || entry.username.length > 256 || /[\u0000-\u001f]/.test(entry.username) || typeof entry.credential !== 'string' || !entry.credential || entry.credential.length > 2048 || /[\u0000-\u001f]/.test(entry.credential)) throw new Error('Invalid relay credentials');
      relay = true; return { urls: accepted, username: entry.username, credential: entry.credential };
    }
    return { urls: accepted };
  }).filter(entry => entry.urls.length > 0);
  if (!relay) throw new Error('No usable relay');
  return { iceServers, ttl: 600 };
}
const roomID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const capability = /^[0-9a-f]{64}$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // Origins are deployment configuration, never reflected from an untrusted request.
    if (url.pathname.startsWith('/v1/')) {
      if (request.headers.get('Origin') && request.headers.get('Origin') !== env.ALLOWED_ORIGIN) return fail(403, 'Origin refused');
      try {
        if (url.pathname === '/v1/rooms' && request.method === 'POST') {
          if (!await authorized(request, env.OPERATOR_TOKEN)) return fail(401, 'Operator authorization required');
          const data = await body(request);
          const capacity = data.capacity ?? 1;
          if (!Number.isInteger(capacity) || Number(capacity) < 1 || Number(capacity) > 10) return fail(400, 'Capacity must be 1–10; hardware qualification is separate');
          const id = crypto.randomUUID();
          return await env.ROOMS.getByName(id).fetch(new Request(`${url.origin}/internal/create`, { method: 'POST', body: JSON.stringify({ capacity, id }) }));
        }
        const match = /^\/v1\/rooms\/([^/]+)\/(socket|turn|invites|end)$/.exec(url.pathname);
        if (!match || !roomID.test(match[1])) return fail(404, 'Unknown endpoint');
        if (['invites', 'end'].includes(match[2])) {
          if (!await authorized(request, env.OPERATOR_TOKEN)) return fail(401, 'Operator authorization required');
        }
        return await env.ROOMS.getByName(match[1]).fetch(request);
      } catch { return fail(400, 'Invalid request'); }
    }
    const response = await env.ASSETS.fetch(request);
    const headers = new Headers(response.headers);
    headers.set('Referrer-Policy', 'no-referrer');
    headers.set('Permissions-Policy', 'camera=(self), microphone=(self), display-capture=(self)');
    headers.set('X-Content-Type-Options', 'nosniff');
    headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' wss:; media-src 'self' blob:; img-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'");
    return new Response(response.body, { status: response.status, headers });
  }
} satisfies ExportedHandler<Env>;

export class InterviewRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS invites (id TEXT PRIMARY KEY, hash TEXT UNIQUE NOT NULL, role TEXT NOT NULL, expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, generation TEXT NOT NULL)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS turn_limits (hash TEXT PRIMARY KEY, requested INTEGER NOT NULL)');
  }
  private room(): Room | undefined { return this.ctx.storage.sql.exec<{value: string}>('SELECT value FROM settings WHERE id=1').toArray().map(row => JSON.parse(row.value) as Room)[0]; }
  private save(room: Room) { this.ctx.storage.sql.exec('INSERT OR REPLACE INTO settings (id,value) VALUES (1,?)', JSON.stringify(room)); }
  private peers() { return this.ctx.getWebSockets().map(socket => ({ socket, peer: socket.deserializeAttachment() as Peer })).filter(({peer}) => this.ctx.storage.sql.exec<{generation: string}>('SELECT generation FROM sessions WHERE id=?', peer.id).toArray()[0]?.generation === peer.generation); }
  private emit(socket: WebSocket, value: unknown) {
    const peer = socket.deserializeAttachment() as Peer;
    if (peer.deliveries.length >= 32) {
      this.ctx.storage.sql.exec('DELETE FROM sessions WHERE id=? AND generation=?', peer.id, peer.generation);
      socket.close(1008, 'Outgoing delivery credit exhausted'); return;
    }
    const delivery = ++peer.nextDelivery; peer.deliveries.push(delivery); socket.serializeAttachment(peer);
    try { socket.send(JSON.stringify({ ...(value as Record<string, unknown>), delivery })); }
    catch { socket.close(1011, 'Delivery failed'); }
  }
  private broadcast(value: unknown) { for (const {socket} of this.peers()) this.emit(socket, value); }
  private roster() { const room = this.room(); this.broadcast({ type: 'roster', peers: this.peers().map(({peer}) => ({ id: peer.id, role: peer.role, name: peer.name, state: peer.state })), program: room?.program ?? false, recording: room?.recording ?? false, locked: room?.locked ?? false }); }
  private async invite(role: Role) {
    const room = this.room()!;
    const secret = token(); const id = crypto.randomUUID(); const hash = await digest(secret);
    // Count and insert share one synchronous turn, even when digest yields.
    if (this.ctx.storage.sql.exec<{count: number}>('SELECT COUNT(*) AS count FROM invites').toArray()[0].count >= 128) return undefined;
    this.ctx.storage.sql.exec('INSERT INTO invites(id,hash,role,expires) VALUES(?,?,?,?)', id, hash, role, room.expires);
    return { id, token: secret, expires: room.expires };
  }
  private async lookup(secret: string): Promise<Invite | undefined> {
    if (!capability.test(secret)) return undefined;
    const hash = await digest(secret);
    return this.ctx.storage.sql.exec<Invite>('SELECT * FROM invites WHERE hash=? AND revoked=0 AND expires>?', hash, Date.now()).toArray()[0];
  }
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/internal/create' && request.method === 'POST') {
      if (this.room()) return fail(409, 'Room already exists');
      const data = await body(request);
      const expires = Date.now() + 2 * 60 * 60 * 1000;
      this.save({ expires, capacity: Number(data.capacity), ended: false, locked: false, program: false, recording: false });
      await this.ctx.storage.setAlarm(expires);
      const host = await this.invite('host'); const guest = await this.invite('guest');
      return json({ id: data.id, expires, host, guest, capacity: data.capacity, qualification: 'Experimental signaling only; native media and capacity are unqualified' }, 201);
    }
    const room = this.room();
    if (!room || room.ended || room.expires <= Date.now()) return fail(410, 'Room ended or expired');
    if (url.pathname.endsWith('/invites') && request.method === 'POST') {
      if (!await authorized(request, this.env.OPERATOR_TOKEN)) return fail(401, 'Operator authorization required');
      const invite = await this.invite('guest');
      return invite ? json(invite, 201) : fail(400, 'Invite limit reached');
    }
    if (url.pathname.endsWith('/end') && request.method === 'POST') {
      if (!await authorized(request, this.env.OPERATOR_TOKEN)) return fail(401, 'Operator authorization required');
      await this.end(); return json({ ended: true });
    }
    if (url.pathname.endsWith('/turn') && request.method === 'POST') {
      const secret = request.headers.get('Authorization')?.replace(/^Bearer /, '') ?? '';
      const invite = await this.lookup(secret);
      const connected = invite && this.peers().find(({peer}) => peer.hash === invite.hash)?.peer;
      if (!invite || !connected) return fail(401, 'Connected peer authorization required');
      if (!this.env.TURN_KEY_ID || !this.env.TURN_KEY_API_TOKEN) return fail(503, 'TURN service is not configured');
      const previous = this.ctx.storage.sql.exec<{requested: number}>('SELECT requested FROM turn_limits WHERE hash=?', invite.hash).toArray()[0];
      if (previous && Date.now() - previous.requested < 60_000) return fail(429, 'TURN refresh rate exceeded');
      this.ctx.storage.sql.exec('INSERT OR REPLACE INTO turn_limits(hash,requested) VALUES(?,?)', invite.hash, Date.now());
      let response: Response;
      try {
        response = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(this.env.TURN_KEY_ID)}/credentials/generate-ice-servers`, { method: 'POST', headers: { Authorization: `Bearer ${this.env.TURN_KEY_API_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ ttl: 600 }), signal: AbortSignal.timeout(8000) });
      } catch { return fail(503, 'TURN provider unavailable'); }
      if (!response.ok) { await response.body?.cancel(); return fail(503, 'TURN provider unavailable'); }
      try {
        const data = await body(response);
        const currentRoom = this.room(); const currentInvite = await this.lookup(secret);
        if (!currentRoom || currentRoom.ended || currentRoom.expires <= Date.now() || !currentInvite || !this.peers().some(({peer}) => peer.hash === invite.hash && peer.generation === connected.generation)) return fail(401, 'Peer authorization changed');
        return json(relayConfiguration(data));
      } catch { return fail(502, 'Invalid TURN response'); }
    }
    if (!url.pathname.endsWith('/socket') || request.method !== 'GET' || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return fail(405, 'WebSocket upgrade required');
    if (request.headers.get('Origin') !== this.env.ALLOWED_ORIGIN) return fail(403, 'Origin refused');
    const protocols = request.headers.get('Sec-WebSocket-Protocol')?.split(',').map(p => p.trim()) ?? [];
    const invite = await this.lookup(protocols.find(p => p.startsWith('cap.'))?.slice(4) ?? '');
    if (!invite || !protocols.includes(protocol)) return fail(401, 'Invalid invite');
    if (room.locked && invite.role === 'guest') return fail(403, 'Room is locked');
    const existing = this.peers().filter(({peer}) => peer.id === invite.id);
    const guestCount = this.peers().filter(({peer}) => peer.role === 'guest' && peer.id !== invite.id).length;
    if (invite.role === 'guest' && guestCount >= room.capacity) return fail(409, 'Room capacity reached');
    for (const {socket} of existing) socket.close(4001, 'Rejoined from another connection');
    const pair = new WebSocketPair(); const client = pair[0], server = pair[1];
    const peer: Peer = { id: invite.id, role: invite.role, hash: invite.hash, name: invite.role === 'host' ? 'Host' : 'Guest', state: 'waiting', generation: crypto.randomUUID(), window: Date.now(), count: 0, ackCount: 0, deliveries: [], nextDelivery: 0 };
    this.ctx.storage.sql.exec('INSERT OR REPLACE INTO sessions(id,generation) VALUES(?,?)', peer.id, peer.generation);
    this.ctx.acceptWebSocket(server); server.serializeAttachment(peer);
    if (peer.role === 'host') {
      // A replacement host owns a new media session. Fence the previous
      // admission before publishing its roster, even if the old close is late.
      room.program = false; room.recording = false; this.save(room);
      for (const guest of this.peers().filter(item => item.peer.role === 'guest')) {
        guest.peer.state = 'waiting'; guest.socket.serializeAttachment(guest.peer);
        this.emit(guest.socket, { type: 'host-disconnected' });
      }
    }
    this.emit(server, { type: 'welcome', id: peer.id, role: peer.role, generation: peer.generation, expires: room.expires });
    this.roster();
    return new Response(null, { status: 101, webSocket: client, headers: { 'Sec-WebSocket-Protocol': protocol } });
  }
  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer) {
    const peer = socket.deserializeAttachment() as Peer;
    const room = this.room();
    if (!room || room.ended || room.expires <= Date.now()) { socket.close(4000, 'Room expired'); return; }
    const invite = this.ctx.storage.sql.exec<Invite>('SELECT * FROM invites WHERE id=?', peer.id).toArray()[0];
    if (!invite || invite.revoked || !this.peers().some(item => item.peer.generation === peer.generation)) { socket.close(4003, 'Invite revoked'); return; }
    if (typeof message !== 'string' || new TextEncoder().encode(message).length > 65536) { socket.close(1009, 'Message exceeds limit'); return; }
    if (Date.now() - peer.window > 1000) { peer.window = Date.now(); peer.count = 0; peer.ackCount = 0; }
    let data: Record<string, unknown>;
    try { const value: unknown = JSON.parse(message); if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(); data = value as Record<string, unknown>; } catch {
      if (++peer.count > 60) { socket.close(1008, 'Rate exceeded'); return; }
      socket.serializeAttachment(peer); this.emit(socket, { type: 'error', error: 'Invalid message' }); return;
    }
    if (data.type === 'ack') {
      if (++peer.ackCount > 240) { socket.close(1008, 'Acknowledgment rate exceeded'); return; }
      if (Number.isSafeInteger(data.delivery)) {
        peer.deliveries = peer.deliveries.filter(delivery => delivery !== data.delivery);
      }
      socket.serializeAttachment(peer);
      return;
    }
    if (++peer.count > 60) { socket.close(1008, 'Rate exceeded'); return; }
    socket.serializeAttachment(peer);
    if (data.type === 'hello') {
      if (typeof data.name !== 'string' || data.name.length > 80) return;
      peer.name = data.name.replace(/[\u0000-\u001f\u007f]/g, '').trim() || 'Guest'; socket.serializeAttachment(peer); this.roster(); return;
    }
    if (data.type === 'ping') { this.emit(socket, { type: 'pong' }); return; }
    if (data.type === 'signal') {
      const target = this.peers().find(item => item.peer.id === data.to);
      if (!target || peer.id === target.peer.id || peer.role === target.peer.role) return;
      const guest = peer.role === 'guest' ? peer : target.peer;
      if (guest.state === 'waiting') return;
      // Generation prevents delayed ICE/SDP from entering a replacement connection.
      if (data.targetGeneration !== target.peer.generation || !['offer','answer','candidate','reset'].includes(String(data.kind))) return;
      if (typeof data.payload !== 'string' || data.payload.length > 60_000) return;
      this.emit(target.socket, { type: 'signal', from: peer.id, generation: peer.generation, targetGeneration: target.peer.generation, kind: data.kind, payload: data.payload }); return;
    }
    if (peer.role !== 'host') { this.emit(socket, { type: 'error', error: 'Host action required' }); return; }
    if (data.type === 'admit' || data.type === 'stage' || data.type === 'backstage' || data.type === 'revoke') {
      const target = this.peers().find(item => item.peer.role === 'guest' && item.peer.id === data.id);
      if (!target) return;
      if (data.type === 'revoke') {
        this.ctx.storage.sql.exec('UPDATE invites SET revoked=1 WHERE id=?', target.peer.id);
        this.ctx.storage.sql.exec('DELETE FROM sessions WHERE id=?', target.peer.id);
        target.socket.close(4003, 'Invite revoked'); this.roster(); return;
      }
      if (data.type === 'stage' && target.peer.state === 'waiting') return;
      target.peer.state = data.type === 'stage' ? 'onair' : 'backstage'; target.socket.serializeAttachment(target.peer);
      // Generations are disclosed only to the paired host/guest after admission.
      this.emit(target.socket, { type: 'admitted', host: peer.id, hostGeneration: peer.generation, state: target.peer.state });
      this.emit(socket, { type: 'admitted', guest: target.peer.id, guestGeneration: target.peer.generation, state: target.peer.state });
      this.roster(); return;
    }
    if (data.type === 'lock' && typeof data.locked === 'boolean') { room.locked = data.locked; this.save(room); this.roster(); return; }
    if (data.type === 'status' && typeof data.program === 'boolean' && typeof data.recording === 'boolean') { room.program = data.program; room.recording = data.recording; this.save(room); this.roster(); return; }
    if (data.type === 'end') await this.end();
  }
  webSocketClose(socket: WebSocket, code: number, reason: string, wasClean: boolean) {
    const closed = socket.deserializeAttachment() as Peer;
    this.ctx.storage.sql.exec('DELETE FROM sessions WHERE id=? AND generation=?', closed.id, closed.generation);
    // A stale replaced host must not tear down the replacement host's session.
    if (closed.role === 'host' && !this.peers().some(({peer, socket: other}) => other !== socket && peer.role === 'host' && peer.generation !== closed.generation)) {
      const room = this.room(); if (room) { room.program = false; room.recording = false; this.save(room); }
      for (const item of this.peers()) if (item.peer.role === 'guest') { item.peer.state = 'waiting'; item.socket.serializeAttachment(item.peer); this.emit(item.socket, { type: 'host-disconnected' }); }
    }
    socket.close(code === 1005 ? 1000 : code, reason); this.roster();
  }
  webSocketError(socket: WebSocket) { socket.close(1011, 'Connection failed'); this.webSocketClose(socket, 1011, 'Connection failed', false); }
  private async end() {
    const room = this.room(); if (room) { room.ended = true; room.program = false; room.recording = false; this.save(room); }
    this.ctx.storage.sql.exec('UPDATE invites SET revoked=1');
    this.ctx.storage.sql.exec('DELETE FROM turn_limits');
    const connections = this.peers();
    this.ctx.storage.sql.exec('DELETE FROM sessions');
    for (const {socket} of connections) { this.emit(socket, { type: 'ended' }); socket.close(4000, 'Room ended'); }
    await this.ctx.storage.deleteAlarm();
  }
  async alarm() { await this.end(); }
}
