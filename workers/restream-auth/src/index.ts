import { DurableObject } from 'cloudflare:workers';
const pattern = /^[A-Za-z0-9_-]{43}$/;
const enc = new TextEncoder();
const random = () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const digest = async (s: string) => btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(s))))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const equal = (a: string, b: string) => a.length === b.length && crypto.subtle.timingSafeEqual(enc.encode(a), enc.encode(b));
class Refusal extends Error { constructor(readonly status: number) { super(`broker_refusal:${status}`); } }
const json = (v: unknown, status = 200) => Response.json(v, { status, headers: { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' } });
async function bytes(response: Request | Response, limit: number): Promise<string> {
  const reader = response.body?.getReader(); if (!reader) throw new Refusal(400);
  const parts: Uint8Array[] = []; let count = 0;
  try { while (true) { const part = await reader.read(); if (part.done) break; count += part.value.length; if (count > limit) throw new Refusal(413); parts.push(part.value); } }
  finally { await reader.cancel(); }
  const value = new Uint8Array(count); let offset = 0; for (const p of parts) { value.set(p, offset); offset += p.length; }
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(value);
}
async function body(request: Request): Promise<Record<string, unknown>> {
  if (request.headers.get('Content-Type') !== 'application/json') throw new Refusal(415);
  const v: unknown = JSON.parse(await bytes(request, 4096));
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Refusal(400); return v as Record<string, unknown>;
}
function origin(env: Env): string {
  if (!env.PUBLIC_ORIGIN || !env.RESTREAM_CLIENT_ID || !env.RESTREAM_CLIENT_SECRET) throw new Refusal(503);
  const u = new URL(env.PUBLIC_ORIGIN);
  if (u.protocol !== 'https:' || u.origin !== env.PUBLIC_ORIGIN || u.username || u.password) throw new Refusal(503); return u.origin;
}
type Token = { access: string; refresh: string; scopes: string[]; expires: number };
type State = { phase: 'waiting' | 'exchanging' | 'ready' | 'active' | 'refreshing'; id: string; challenge: string; nativeState: string; providerState: string; expires: number; token?: Token; owner?: string };
type Grant = { access_token: string; scope: string[]; expires_in: number };
const grant = (t: Token): Grant => ({ access_token: t.access, scope: t.scopes, expires_in: Math.max(1, Math.floor((t.expires - Date.now()) / 1000)) });
export class RestreamAuthorization extends DurableObject<Env> {
  private refreshJob?: Promise<Grant>;
  constructor(ctx: DurableObjectState, env: Env) { super(ctx, env); ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS authorization (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL)'); }
  private read(): State {
    const row = this.ctx.storage.sql.exec<{ value: string }>('SELECT value FROM authorization WHERE id=1').toArray()[0]; if (!row) throw new Refusal(401);
    const s = JSON.parse(row.value) as State; if (s.expires <= Date.now()) { this.ctx.storage.sql.exec('DELETE FROM authorization'); throw new Refusal(401); } return s;
  }
  private write(s: State): void { this.ctx.storage.sql.exec('INSERT OR REPLACE INTO authorization VALUES (1, ?)', JSON.stringify(s)); }
  private async respond(operation: () => Promise<Response>): Promise<Response> {
    try { return await operation(); } catch (e) { return json({ error: 'authorization_unavailable' }, e instanceof Refusal ? e.status : 502); }
  }
  async begin(id: string, challenge: string, nativeState: string): Promise<Response> { return this.respond(() => this.beginAttempt(id, challenge, nativeState)); }
  async callback(state: string, code: string): Promise<Response> { return this.respond(() => this.acceptCallback(state, code)); }
  async complete(verifier: string): Promise<Response> { return this.respond(() => this.acceptProof(verifier)); }
  async refresh(credential: string, knownAccess: string): Promise<Response> { return this.respond(() => this.refreshOwned(credential, knownAccess)); }
  async forget(credential: string): Promise<Response> { return this.respond(async () => { await this.owned(credential); this.ctx.storage.sql.exec('DELETE FROM authorization'); return json({ disconnected: true }); }); }
  private async beginAttempt(id: string, challenge: string, nativeState: string): Promise<Response> {
    if (this.ctx.storage.sql.exec('SELECT id FROM authorization').toArray().length) throw new Refusal(409);
    const s: State = { id, challenge, nativeState, providerState: `${id}.${random()}`, phase: 'waiting', expires: Date.now() + 600_000 };
    this.write(s); await this.ctx.storage.setAlarm(s.expires);
    const u = new URL('https://api.restream.io/login'); u.search = new URLSearchParams({ response_type: 'code', client_id: this.env.RESTREAM_CLIENT_ID, redirect_uri: origin(this.env) + '/oauth/callback', state: s.providerState }).toString();
    return json({ attempt: id, authorization_url: u.href });
  }
  private async exchange(fields: Record<string, string>, previous?: Token): Promise<Token> {
    const response = await fetch('https://api.restream.io/oauth/token', { method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(15_000), headers: { 'Content-Type': 'application/x-www-form-urlencoded', Authorization: `Basic ${btoa(this.env.RESTREAM_CLIENT_ID + ':' + this.env.RESTREAM_CLIENT_SECRET)}` }, body: new URLSearchParams(fields) });
    if (response.status !== 200) { await response.body?.cancel(); throw new Refusal(401); }
    const v = JSON.parse(await bytes(response, 65_536)) as Record<string, unknown>;
    const access = v.access_token, refresh = v.refresh_token ?? previous?.refresh, scopes = typeof v.scope === 'string' ? v.scope.split(' ').filter(Boolean) : previous?.scopes;
    if (typeof access !== 'string' || !/^[\x21-\x7e]{1,16384}$/.test(access) || typeof refresh !== 'string' || !/^[\x21-\x7e]{1,16384}$/.test(refresh) || !scopes || scopes.length > 100 || !scopes.every(s => s.length > 0 && s.length <= 256) || typeof v.expires_in !== 'number' || !Number.isFinite(v.expires_in) || v.expires_in <= 60) throw new Refusal(502);
    return { access, refresh, scopes, expires: Date.now() + Math.min(v.expires_in, 86400) * 1000 };
  }
  private async acceptCallback(state: string, code: string): Promise<Response> {
    const s = this.read(); if (s.phase !== 'waiting' || !equal(s.providerState, state)) throw new Refusal(401);
    s.phase = 'exchanging'; this.write(s); // Spend before I/O; code requests never replay.
    const token = await this.exchange({ grant_type: 'authorization_code', code, redirect_uri: origin(this.env) + '/oauth/callback' });
    const current = this.read(); if (current.phase !== 'exchanging') throw new Refusal(401);
    current.phase = 'ready'; current.token = token; this.write(current);
    const u = new URL('streamchat://oauth'); u.search = new URLSearchParams({ attempt: s.id, state: s.nativeState }).toString();
    return new Response(null, { status: 302, headers: { Location: u.href, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });
  }
  private async acceptProof(verifier: string): Promise<Response> {
    const hash = await digest(verifier), s = this.read(); if (s.phase !== 'ready' || !s.token || !equal(s.challenge, hash)) throw new Refusal(401);
    const credential = random(); s.owner = await digest(credential);
    if (this.read().phase !== 'ready') throw new Refusal(409); // Fence concurrent proof completion.
    s.phase = 'active'; s.expires = Date.now() + 30 * 86400_000; this.write(s); await this.ctx.storage.setAlarm(s.expires);
    return json({ ...grant(s.token), session: s.id, credential });
  }
  private async owned(credential: string): Promise<State> {
    const hash = await digest(credential), s = this.read();
    if (!['active', 'refreshing'].includes(s.phase) || !s.owner || !equal(hash, s.owner)) throw new Refusal(401); return s;
  }
  private async accessDigest(access: string): Promise<string> { return digest(access); }
  private async refreshOwned(credential: string, knownAccess: string): Promise<Response> {
    const s = await this.owned(credential); if (this.refreshJob) return json(await this.refreshJob);
    if (s.phase === 'refreshing') { this.ctx.storage.sql.exec('DELETE FROM authorization'); throw new Refusal(401); } // Unknown interrupted rotation: require consent.
    if (!s.token) throw new Refusal(401);
    const hash = await this.accessDigest(s.token.access);
    if (this.refreshJob) return json(await this.refreshJob);
    // Hashing yields: forget/expiry/another completed rotation can retire the
    // captured record. Cached recovery must revalidate the live owner too.
    const current = this.read(); if (current.phase !== 'active' || current.owner !== s.owner || !current.token) throw new Refusal(401);
    if ((!equal(hash, knownAccess) || current.token.access !== s.token.access) && current.token.expires > Date.now() + 60_000) return json(grant(current.token));
    current.phase = 'refreshing'; this.write(current); // Persist rotation ownership before external I/O.
    const job = this.rotate(current); this.refreshJob = job;
    try { return json(await job); } finally { if (this.refreshJob === job) this.refreshJob = undefined; }
  }
  private async rotate(s: State): Promise<Grant> {
    try {
      const token = await this.exchange({ grant_type: 'refresh_token', refresh_token: s.token!.refresh }, s.token);
      const current = this.read(); if (current.phase !== 'refreshing' || current.owner !== s.owner) throw new Refusal(401);
      current.phase = 'active'; current.token = token; this.write(current); return grant(token);
    } catch (error) { this.ctx.storage.sql.exec('DELETE FROM authorization'); throw error; }
  }
  async alarm(): Promise<void> {
    const row = this.ctx.storage.sql.exec<{value: string}>('SELECT value FROM authorization WHERE id=1').toArray()[0];
    if (!row) return;
    const expires = (JSON.parse(row.value) as State).expires;
    if (expires > Date.now()) { await this.ctx.storage.setAlarm(expires); return; }
    this.ctx.storage.sql.exec('DELETE FROM authorization');
  }
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const u = new URL(request.url); if (u.origin !== origin(env)) throw new Refusal(400);
      if (request.method === 'POST' && request.headers.has('Origin')) throw new Refusal(403);
      if (request.method === 'POST' && u.pathname === '/v1/attempts' && !u.search) {
        if (!(await env.ATTEMPTS.limit({ key: request.headers.get('CF-Connecting-IP') ?? 'local' })).success) throw new Refusal(429);
        const v = await body(request); if (typeof v.challenge !== 'string' || !pattern.test(v.challenge) || typeof v.state !== 'string' || !pattern.test(v.state)) throw new Refusal(400);
        const id = random(); return await env.SESSIONS.getByName(id).begin(id, v.challenge, v.state);
      }
      if (request.method === 'GET' && u.pathname === '/oauth/callback') {
        const states = u.searchParams.getAll('state'), codes = u.searchParams.getAll('code');
        if (states.length !== 1 || codes.length !== 1 || u.searchParams.has('error') || codes[0].length > 8192 || !codes[0]) throw new Refusal(400);
        const [id, secret, extra] = states[0].split('.'); if (extra || !pattern.test(id) || !pattern.test(secret)) throw new Refusal(400);
        return await env.SESSIONS.getByName(id).callback(states[0], codes[0]);
      }
      const m = /^\/v1\/sessions\/([A-Za-z0-9_-]{43})\/(complete|refresh|forget)$/.exec(u.pathname);
      if (request.method !== 'POST' || !m || u.search) throw new Refusal(404);
      const stub = env.SESSIONS.getByName(m[1]), v = await body(request);
      if (m[2] === 'complete') { if (typeof v.verifier !== 'string' || !pattern.test(v.verifier)) throw new Refusal(400); return await stub.complete(v.verifier); }
      const credential = request.headers.get('Authorization')?.replace(/^Bearer /, ''); if (!credential || !pattern.test(credential)) throw new Refusal(401);
      if (m[2] === 'forget') return await stub.forget(credential);
      if (typeof v.known_access !== 'string' || !pattern.test(v.known_access)) throw new Refusal(400); return await stub.refresh(credential, v.known_access);
    } catch (e) { return json({ error: 'authorization_unavailable' }, e instanceof Refusal ? e.status : e instanceof Error && /^broker_refusal:[0-9]{3}$/.test(e.message) ? Number(e.message.slice(-3)) : 502); }
  },
} satisfies ExportedHandler<Env>;
