import { env, exports } from 'cloudflare:workers';
import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

type Invite = { id: string; token: string; expires: number };
type CreatedRoom = { id: string; host: Invite; guest: Invite; expires: number; capacity: number };
type Message = Record<string, unknown>;
const origin = 'https://interviews.example.test';
const operator = 'test-only-operator-token';
const rooms: CreatedRoom[] = [];
const sockets: Connection[] = [];

async function request(path: string, options: RequestInit = {}) {
  return exports.default.fetch(new Request(origin + path, options));
}
async function create(capacity = 2) {
  const response = await request('/v1/rooms', { method: 'POST', headers: { Authorization: `Bearer ${operator}` }, body: JSON.stringify({ capacity }) });
  expect(response.status).toBe(201);
  const room = await response.json<CreatedRoom>(); rooms.push(room); return room;
}
async function invite(room: CreatedRoom) {
  const response = await request(`/v1/rooms/${room.id}/invites`, { method: 'POST', headers: { Authorization: `Bearer ${operator}` } });
  expect(response.status).toBe(201); return response.json<Invite>();
}
async function upgrade(room: CreatedRoom, invite: Invite, override: Record<string, string> = {}) {
  return request(`/v1/rooms/${room.id}/socket`, { headers: { Upgrade: 'websocket', Origin: origin, 'Sec-WebSocket-Protocol': `stream-interview-v1, cap.${invite.token}`, ...override } });
}
async function waitUntil(condition: () => boolean, message: string) {
  const deadline = Date.now() + 2_000;
  while (!condition() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 5));
  expect(condition(), message).toBe(true);
}
class Connection {
  readonly messages: Message[] = [];
  closeCode?: number;
  constructor(readonly socket: WebSocket, acknowledge = true) {
    socket.addEventListener('message', event => { const message = JSON.parse(String(event.data)) as Message; this.messages.push(message); if (acknowledge && Number.isSafeInteger(message.delivery) && socket.readyState === WebSocket.OPEN) { try { socket.send(JSON.stringify({type:'ack',delivery:message.delivery})); } catch {} } });
    socket.addEventListener('close', event => { this.closeCode = event.code; });
    socket.accept(); sockets.push(this);
  }
  send(value: Message) { this.socket.send(JSON.stringify(value)); }
  async next(type: string, since = 0) {
    await waitUntil(() => this.messages.slice(since).some(message => message.type === type), `Missing ${type}`);
    return this.messages.slice(since).find(message => message.type === type)!;
  }
  async barrier() { const cursor = this.messages.length; this.send({ type: 'ping' }); await this.next('pong', cursor); }
  get welcome() { return this.messages.find(message => message.type === 'welcome')!; }
  get id() { return this.welcome.id as string; }
  get generation() { return this.welcome.generation as string; }
  get roster() { return this.messages.filter(message => message.type === 'roster').at(-1)!; }
}
async function connect(room: CreatedRoom, invite: Invite, acknowledge = true) {
  const response = await upgrade(room, invite);
  expect(response.status).toBe(101);
  expect(response.headers.get('Sec-WebSocket-Protocol')).toBe('stream-interview-v1');
  expect(response.headers.get('Sec-WebSocket-Protocol')).not.toContain(invite.token);
  const connection = new Connection(response.webSocket!, acknowledge); await connection.next('welcome'); await connection.next('roster'); return connection;
}
async function admit(host: Connection, guest: Connection) {
  const cursor = guest.messages.length; host.send({ type: 'admit', id: guest.id }); await guest.next('admitted', cursor); await host.barrier();
}
const signal = (peer: Connection, payload = 'fixture-sdp-marker') => ({ type: 'signal', to: peer.id, targetGeneration: peer.generation, kind: 'offer', payload });
async function noSignal(sender: Connection, target: Connection, value: Message) {
  const before = target.messages.filter(message => message.type === 'signal').length;
  sender.send(value); await sender.barrier(); await target.barrier();
  expect(target.messages.filter(message => message.type === 'signal')).toHaveLength(before);
}
async function turn(room: CreatedRoom, invite: Invite) {
  return request(`/v1/rooms/${room.id}/turn`, { method: 'POST', headers: { Authorization: `Bearer ${invite.token}` } });
}

beforeEach(() => {
  // Intercept the actual provider fetch boundary; every unmatched outbound
  // request throws rather than contacting a deployed TURN service.
  vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Unmocked outbound request refused'));
});
afterEach(async () => {
  for (const room of rooms.splice(0)) await request(`/v1/rooms/${room.id}/end`, { method: 'POST', headers: { Authorization: `Bearer ${operator}` } });
  for (const peer of sockets.splice(0)) {
    if (peer.socket.readyState === WebSocket.OPEN) peer.socket.close(1000, 'Fixture finished');
  }
  vi.restoreAllMocks();
});

describe('actual Worker and SQLite Durable Object interview signaling', () => {
  it('requires operator authority, exact origins and bounded valid create bodies', async () => {
    expect((await request('/v1/rooms', { method: 'POST', body: '{}' })).status).toBe(401);
    expect((await request('/v1/rooms', { method: 'POST', headers: { Authorization: `Bearer ${operator}`, Origin: 'https://attacker.invalid' }, body: '{}' })).status).toBe(403);
    for (const capacity of [0, 11, 1.5, '2']) {
      expect((await request('/v1/rooms', { method: 'POST', headers: { Authorization: `Bearer ${operator}` }, body: JSON.stringify({ capacity }) })).status).toBe(400);
    }
    expect((await request('/v1/rooms', { method: 'POST', headers: { Authorization: `Bearer ${operator}` }, body: JSON.stringify({ marker: 'x'.repeat(8192) }) })).status).toBe(400);
    const room = await create(1);
    expect(room.host.token).toMatch(/^[0-9a-f]{64}$/); expect(room.guest.token).not.toBe(room.host.token);
    expect(room.expires - Date.now()).toBeGreaterThan(7_190_000);
    expect((await request(`/v1/rooms/${room.id}/invites`, { method: 'POST', headers: { Authorization: `Bearer ${room.host.token}` } })).status).toBe(401);
    expect((await request(`/v1/rooms/${room.id}/end`, { method: 'POST' })).status).toBe(401);
    expect((await upgrade(room, room.guest, { Origin: 'https://attacker.invalid' })).status).toBe(403);
    expect((await upgrade(room, room.guest, { 'Sec-WebSocket-Protocol': `stream-interview-v1, cap.${'0'.repeat(64)}` })).status).toBe(401);
    expect((await upgrade(room, room.guest, { 'Sec-WebSocket-Protocol': `cap.${room.guest.token}` })).status).toBe(401);
  });

  it('stores only hashed capabilities and no SDP or ICE payloads', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest);
    await admit(host, guest); host.send(signal(guest, 'PRIVATE_SDP_FIXTURE')); await guest.next('signal');
    const persisted = await runInDurableObject(env.ROOMS.getByName(room.id), (_instance, state) => {
      const tables = ['settings', 'invites', 'sessions', 'turn_limits'];
      return tables.map(table => JSON.stringify(state.storage.sql.exec(`SELECT * FROM ${table}`).toArray())).join('\n');
    });
    expect(persisted).not.toContain(room.host.token); expect(persisted).not.toContain(room.guest.token);
    expect(persisted).not.toContain(operator); expect(persisted).not.toContain('PRIVATE_SDP_FIXTURE');
    expect(persisted).toContain('"hash"'); expect(persisted).toContain(host.generation);
  });

  it('refuses self-admission, waiting/stale/guest-to-guest signaling and staging without admission', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest), other = await connect(room, await invite(room));
    guest.send({ type: 'admit', id: guest.id }); expect((await guest.next('error')).error).toBe('Host action required');
    host.send({ type: 'stage', id: guest.id }); await host.barrier(); await guest.barrier();
    expect(guest.messages.some(message => message.type === 'admitted')).toBe(false);
    await noSignal(guest, host, signal(host)); await noSignal(host, guest, signal(guest));
    await admit(host, guest); await admit(host, other);
    await noSignal(guest, other, signal(other));
    await noSignal(host, guest, { ...signal(guest), targetGeneration: crypto.randomUUID() });
    await noSignal(host, guest, { ...signal(guest), kind: 'unknown' });
    const cursor = guest.messages.length; host.send(signal(guest));
    expect(await guest.next('signal', cursor)).toMatchObject({ from: host.id, generation: host.generation, targetGeneration: guest.generation, payload: 'fixture-sdp-marker' });
    const guestCursor = guest.messages.length; host.send({ type: 'stage', id: guest.id });
    expect((await guest.next('admitted', guestCursor)).state).toBe('onair');
    host.send({ type: 'backstage', id: guest.id }); await host.barrier(); await guest.barrier();
    expect((guest.roster.peers as Message[]).find(peer => peer.id === guest.id)?.state).toBe('backstage');
  });

  it('enforces guest capacity and host-controlled lock; guest status never sets program or recording', async () => {
    const room = await create(1), host = await connect(room, room.host), guest = await connect(room, room.guest);
    const spare = await invite(room);
    expect((await upgrade(room, spare)).status).toBe(409);
    guest.send({ type: 'status', program: true, recording: true }); await guest.barrier();
    expect(guest.roster.program).toBe(false); expect(guest.roster.recording).toBe(false);
    host.send({ type: 'lock', locked: true }); await host.barrier();
    expect((await upgrade(room, room.guest)).status).toBe(403);
    host.send({ type: 'lock', locked: false }); await host.barrier();
    host.send({ type: 'status', program: true, recording: true }); await host.barrier(); await guest.barrier();
    expect(guest.roster).toMatchObject({ program: true, recording: true, locked: false });
  });

  it('rejoining replaces one invite generation and resets guest admission', async () => {
    const room = await create(1), host = await connect(room, room.host), oldGuest = await connect(room, room.guest);
    await admit(host, oldGuest); const replacement = await connect(room, room.guest);
    await waitUntil(() => oldGuest.closeCode !== undefined, 'Old invite connection was not closed');
    expect(oldGuest.closeCode).toBe(4001); expect(replacement.generation).not.toBe(oldGuest.generation);
    await host.barrier(); await replacement.barrier();
    expect((replacement.roster.peers as Message[]).filter(peer => peer.role === 'guest')).toHaveLength(1);
    expect((replacement.roster.peers as Message[]).find(peer => peer.id === replacement.id)?.state).toBe('waiting');
    await noSignal(replacement, host, signal(host)); await admit(host, replacement);
    await noSignal(host, replacement, { ...signal(replacement), targetGeneration: oldGuest.generation });
    host.send(signal(replacement)); await replacement.next('signal');
  });

  it('host replacement preserves new host status; genuine host loss clears admission and status', async () => {
    const room = await create(), oldHost = await connect(room, room.host), guest = await connect(room, room.guest);
    await admit(oldHost, guest); oldHost.send({ type: 'status', program: true, recording: true }); await oldHost.barrier();
    const host = await connect(room, room.host);
    await waitUntil(() => oldHost.closeCode !== undefined, 'Replaced host did not close');
    host.send({ type: 'status', program: true, recording: true }); await host.barrier(); await guest.barrier();
    expect(guest.roster).toMatchObject({ program: true, recording: true });
    const disconnectCursor = guest.messages.length; host.socket.close(1000, 'Host leaving');
    await guest.next('host-disconnected', disconnectCursor); await guest.barrier();
    expect(guest.roster).toMatchObject({ program: false, recording: false });
    expect((guest.roster.peers as Message[]).find(peer => peer.id === guest.id)?.state).toBe('waiting');
  });

  it('a new host generation fences the previous admission before explicit readmission', async () => {
    const room = await create(), oldHost = await connect(room, room.host), guest = await connect(room, room.guest);
    await admit(oldHost, guest); oldHost.send({ type: 'stage', id: guest.id });
    oldHost.send({ type: 'status', program: true, recording: true }); await oldHost.barrier(); await guest.barrier();
    expect((guest.roster.peers as Message[]).find(peer => peer.id === guest.id)?.state).toBe('onair');
    const cursor = guest.messages.length, host = await connect(room, room.host);
    expect(host.generation).not.toBe(oldHost.generation);
    await guest.next('host-disconnected', cursor); await guest.barrier();
    expect(guest.roster).toMatchObject({ program: false, recording: false });
    expect((guest.roster.peers as Message[]).find(peer => peer.id === guest.id)?.state).toBe('waiting');
    await noSignal(guest, host, signal(host, 'OLD_ADMISSION'));
    await noSignal(host, guest, signal(guest, 'NO_IMPLICIT_ADMISSION'));
    await admit(host, guest);
    host.send({ type: 'status', program: true, recording: true }); await host.barrier(); await guest.barrier();
    await waitUntil(() => oldHost.closeCode !== undefined, 'Superseded host did not close');
    expect(guest.roster).toMatchObject({ program: true, recording: true });
    expect((guest.roster.peers as Message[]).find(peer => peer.id === guest.id)?.state).toBe('backstage');
  });

  it('reconstructs the real object after hibernation with roles, generations, admission and status intact', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest);
    await admit(host, guest); host.send({ type: 'status', program: true, recording: false }); await host.barrier();
    await evictDurableObject(env.ROOMS.getByName(room.id));
    await host.barrier(); await guest.barrier();
    const cursor = guest.messages.length; host.send(signal(guest, 'AFTER_HIBERNATION')); await guest.next('signal', cursor);
    host.send({ type: 'stage', id: guest.id }); await host.barrier(); await guest.barrier();
    expect(guest.roster).toMatchObject({ program: true, recording: false });
    expect((guest.roster.peers as Message[]).find(peer => peer.id === guest.id)?.state).toBe('onair');
  });

  it('revokes connected guest authority, rejects expired invites and ends the room through its actual alarm', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest);
    host.send({ type: 'revoke', id: guest.id }); await waitUntil(() => guest.closeCode !== undefined, 'Revoked guest stayed connected');
    expect(guest.closeCode).toBe(4003); expect((await upgrade(room, room.guest)).status).toBe(401);
    expect((await turn(room, room.guest)).status).toBe(401);
    const expired = await invite(room);
    await runInDurableObject(env.ROOMS.getByName(room.id), (_instance, state) => state.storage.sql.exec('UPDATE invites SET expires=? WHERE id=?', Date.now() - 1, expired.id).toArray());
    expect((await upgrade(room, expired)).status).toBe(401);
    expect(await runDurableObjectAlarm(env.ROOMS.getByName(room.id))).toBe(true);
    await host.next('ended'); await waitUntil(() => host.closeCode !== undefined, 'Alarm left host connected');
    expect(host.closeCode).toBe(4000);
    expect((await upgrade(room, room.host)).status).toBe(410);
    expect((await request(`/v1/rooms/${room.id}/invites`, { method: 'POST', headers: { Authorization: `Bearer ${operator}` } })).status).toBe(410);
    expect(await runDurableObjectAlarm(env.ROOMS.getByName(room.id))).toBe(false);
  });

  it('bounds WebSocket bytes and rates and leaves healthy peers responsive', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest);
    guest.socket.send('x'.repeat(65537)); await waitUntil(() => guest.closeCode !== undefined, 'Oversized socket stayed open');
    expect(guest.closeCode).toBe(1009); await host.barrier();
    const flooded = await connect(room, await invite(room));
    for (let index = 0; index < 61; index++) flooded.send({ type: 'ping' });
    await waitUntil(() => flooded.closeCode !== undefined, 'Rate-limited socket stayed open');
    expect(flooded.closeCode).toBe(1008); await host.barrier();
  });

  it('bounds outgoing delivery credit and closes only an unacknowledged receiver', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest, false);
    await admit(host, guest);
    for (let index=0; index<35; index++) {
      host.send(signal(guest));
      await new Promise(resolve=>setTimeout(resolve,5));
      if (guest.closeCode !== undefined) break;
    }
    await waitUntil(()=>guest.closeCode!==undefined, 'Stalled receiver stayed connected');
    expect(guest.closeCode).toBe(1008);
    expect(guest.messages).toHaveLength(32);
    await host.barrier();
    expect(host.closeCode).toBeUndefined();
  });

  it('issues only scoped sanitized TURN credentials to connected nonrevoked peers and rate limits refresh', async () => {
    const room = await create(), host = await connect(room, room.host);
    expect((await turn(room, room.guest)).status).toBe(401);
    const upstream = { iceServers: [{ urls: ['stun:stun.cloudflare.com:3478', 'turn:turn.cloudflare.com:3478?transport=udp'], username: 'fixture-user', credential: 'fixture-turn-secret' }], internal: 'PRIVATE_PROVIDER_METADATA' };
    const fetch = vi.mocked(globalThis.fetch).mockImplementation(async () => new Response(JSON.stringify(upstream), { headers: { 'Content-Type': 'application/json' } }));
    const response = await turn(room, room.host);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ iceServers: upstream.iceServers, ttl: 600 });
    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, options] = fetch.mock.calls[0];
    expect(String(url)).toBe('https://rtc.live.cloudflare.com/v1/turn/keys/fixture-key/credentials/generate-ice-servers');
    expect((options?.headers as Record<string, string>).Authorization).toBe('Bearer fixture-turn-provider-token');
    expect(JSON.parse(String(options?.body))).toEqual({ ttl: 600 });
    expect((await turn(room, room.host)).status).toBe(429); expect(fetch).toHaveBeenCalledTimes(1);
    host.send({ type: 'end' }); await host.next('ended');
    expect((await turn(room, room.host)).status).toBe(410);
  });

  it('fails malformed, unsafe, oversized or unavailable TURN responses without leaking provider content', async () => {
    const payloads = [
      '{}', '{"iceServers":[]}',
      JSON.stringify({ iceServers: [{ urls: ['https://attacker.invalid/turn'], username: 'user', credential: 'secret' }] }),
      JSON.stringify({ iceServers: [{ urls: ['turn:turn.cloudflare.com:53'], username: 'user', credential: 'secret' }] }),
      JSON.stringify({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: '', credential: 'secret' }] }),
      JSON.stringify({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: 'user', credential: 'bad\nsecret' }] }),
      JSON.stringify({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: 'user', credential: 'secret' }], padding: 'x'.repeat(8192) }),
    ];
    for (const payload of payloads) {
      const room = await create(); await connect(room, room.host);
      vi.mocked(globalThis.fetch).mockImplementationOnce(async () => new Response(payload));
      const response = await turn(room, room.host); expect(response.status).toBe(502);
      expect(await response.json()).toEqual({ error: 'Invalid TURN response' });
    }
    const room = await create(); await connect(room, room.host);
    vi.mocked(globalThis.fetch).mockImplementationOnce(async () => new Response('SECRET_PROVIDER_BODY', { status: 503 }));
    const response = await turn(room, room.host); expect(response.status).toBe(503);
    expect(await response.text()).not.toContain('SECRET_PROVIDER_BODY');
  });
  it('keeps the persisted invite ceiling under concurrent operator requests', async () => {
    const room = await create();
    for (let index = 0; index < 125; index++) await invite(room);
    const requests = await Promise.all([0, 1].map(() => request(`/v1/rooms/${room.id}/invites`, {
      method: 'POST', headers: { Authorization: `Bearer ${operator}` },
    })));
    expect(requests.map(response => response.status).sort()).toEqual([201, 400]);
    const count = await runInDurableObject(env.ROOMS.getByName(room.id), (_instance, state) =>
      state.storage.sql.exec<{count: number}>('SELECT COUNT(*) AS count FROM invites').one().count);
    expect(count).toBe(128);
  });

  it('does not deliver newly generated TURN credentials after the requesting invite was revoked', async () => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let entered = false;
    vi.mocked(globalThis.fetch).mockImplementationOnce(async () => {
      entered = true; await gate;
      return new Response(JSON.stringify({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: 'user', credential: 'LATE_CREDENTIAL_FIXTURE' }] }));
    });
    const pending = turn(room, room.guest);
    try {
      await waitUntil(() => entered, 'TURN provider was not called');
      host.send({ type: 'revoke', id: guest.id }); await waitUntil(() => guest.closeCode !== undefined, 'Guest revoke did not complete');
    } finally { release(); }
    const response = await pending;
    expect(response.status).toBe(401); expect(await response.text()).not.toContain('LATE_CREDENTIAL_FIXTURE');
  });

  it('rejects unusable TURN port numbers as malformed provider data', async () => {
    for (const port of [0, 99999]) {
      const room = await create(); await connect(room, room.host);
      vi.mocked(globalThis.fetch).mockImplementationOnce(async () => new Response(JSON.stringify({ iceServers: [{ urls: [`turn:turn.cloudflare.com:${port}`], username: 'user', credential: 'secret' }] })));
      expect((await turn(room, room.host)).status).toBe(502);
    }
  });

  it.each(['rejoin', 'end', 'expiry'] as const)('rejects late TURN credentials after requesting session %s', async action => {
    const room = await create(), host = await connect(room, room.host), guest = await connect(room, room.guest);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    let entered = false;
    vi.mocked(globalThis.fetch).mockImplementationOnce(async () => {
      entered = true; await gate;
      return new Response(JSON.stringify({ iceServers: [{ urls: ['turn:turn.cloudflare.com:3478'], username: 'user', credential: 'LATE_CREDENTIAL_FIXTURE' }] }));
    });
    const pending = turn(room, room.guest);
    try {
      await waitUntil(() => entered, 'TURN provider was not called');
      if (action === 'rejoin') {
        const replacement = await connect(room, room.guest);
        expect(replacement.generation).not.toBe(guest.generation);
        await waitUntil(() => guest.closeCode !== undefined, 'Old guest did not close after replacement');
      } else if (action === 'end') {
        host.send({ type: 'end' }); await host.next('ended');
      } else {
        await runInDurableObject(env.ROOMS.getByName(room.id), (_instance, state) => {
          const row = state.storage.sql.exec<{value: string}>('SELECT value FROM settings WHERE id=1').one();
          state.storage.sql.exec('UPDATE settings SET value=? WHERE id=1', JSON.stringify({ ...JSON.parse(row.value), expires: Date.now() - 1 }));
        });
        expect((await upgrade(room, room.host)).status).toBe(410);
      }
    } finally { release(); }
    const response = await pending;
    expect(response.status).toBe(401); expect(await response.text()).not.toContain('LATE_CREDENTIAL_FIXTURE');
  });

});
