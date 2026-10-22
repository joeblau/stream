import worker from '../src/index';
import { env, exports } from 'cloudflare:workers';
import { runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { beforeEach, afterEach, expect, it } from 'vitest';
const origin = 'https://broker.example.test';
const verifier = 'v'.repeat(43), nativeState = 'n'.repeat(43);
const digest = async (s: string) => btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
type Attempt = { attempt: string; authorization_url: string };
type Grant = { session: string; credential: string; access_token: string; expires_in: number; scope: string[] };
type Fixture = { calls: { url: string; authorization: string; body: string }[]; entered: boolean };
const control = async (path = '/status') => (await fetch('https://fixture-control.test' + path)).json<Fixture>();
async function entered() { for (let i = 0; i < 1000; i++) { if ((await control()).entered) return; await new Promise(r => setTimeout(r, 2)); } throw new Error('Fixture did not enter'); }
const request = (path: string, value: unknown, credential?: string) => exports.default.fetch(new Request(origin + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(credential ? { Authorization: `Bearer ${credential}` } : {}) }, body: JSON.stringify(value) }));
async function begin(): Promise<Attempt> { const r = await request('/v1/attempts', { challenge: await digest(verifier), state: nativeState }); expect(r.status).toBe(200); return r.json<Attempt>(); }
async function callback(a: Attempt, extra = '') { const u = new URL(a.authorization_url); return exports.default.fetch(new Request(origin + '/oauth/callback?code=fixture-code&state=' + encodeURIComponent(u.searchParams.get('state')!) + extra, { redirect: 'manual' })); }
async function authorized(): Promise<Grant> { const a = await begin(); expect((await callback(a)).status).toBe(302); const r = await request(`/v1/sessions/${a.attempt}/complete`, { verifier }); expect(r.status).toBe(200); return r.json<Grant>(); }
beforeEach(async () => { await control('/reset'); });
afterEach(async () => { await control('/release'); });
it('keeps confidential exchange on server; binds state, fixed callback and one-use S256 completion', async () => {
  const a = await begin(), url = new URL(a.authorization_url);
  expect(url.origin + url.pathname).toBe('https://api.restream.io/login'); expect(url.searchParams.get('redirect_uri')).toBe(origin + '/oauth/callback');
  expect((await callback(a, '&state=duplicate')).status).toBe(400);
  const r = await callback(a); expect(r.status).toBe(302);
  const target = new URL(r.headers.get('Location')!); expect(target.origin + target.pathname).toBe('null');
  expect(target.protocol).toBe('streamchat:'); expect(target.hostname).toBe('oauth'); expect(target.searchParams.get('state')).toBe(nativeState); expect(target.searchParams.get('attempt')).toBe(a.attempt);
  expect((await callback(a)).status).toBe(401);
  expect((await request(`/v1/sessions/${a.attempt}/complete`, { verifier: 'x'.repeat(43) })).status).toBe(401);
  const grant = await request(`/v1/sessions/${a.attempt}/complete`, { verifier }); expect(grant.status).toBe(200);
  const text = await grant.text(); expect(text).not.toContain('refresh-1'); expect(text).not.toContain('fixture-server-secret');
  expect((await request(`/v1/sessions/${a.attempt}/complete`, { verifier })).status).toBe(401);
  const call = (await control()).calls[0]; expect(call.url).toBe('https://api.restream.io/oauth/token');
  expect(call.authorization).toBe('Basic ' + btoa('fixture-client:fixture-server-secret'));
  expect(call.body).toContain('redirect_uri=https%3A%2F%2Fbroker.example.test%2Foauth%2Fcallback');
});
it('coalesces owned rotations, preserves the rotated server refresh token and recovers a lost reply without rotating again', async () => {
  const g = await authorized(); await control('/hold');
  const hash = await digest(g.access_token), path = `/v1/sessions/${g.session}/refresh`;
  const a = request(path, { known_access: hash }, g.credential); await entered();
  const b = request(path, { known_access: hash }, g.credential); await control('/release');
  expect((await a).status).toBe(200); expect((await b).status).toBe(200); expect((await control()).calls).toHaveLength(2);
  const recovered = await request(path, { known_access: hash }, g.credential); expect((await recovered.json<Grant>()).access_token).toBe('access-2'); expect((await control()).calls).toHaveLength(2);
  expect((await request(path, { known_access: hash }, 'z'.repeat(43))).status).toBe(401);
  await request(path, { known_access: await digest('access-2') }, g.credential);
  expect((await control()).calls.at(-1)!.body).toContain('refresh_token=refresh-2');
});
it('revokes broker ownership during held refresh and refuses late persistence', async () => {
  const g = await authorized(); await control('/hold');
  const path = `/v1/sessions/${g.session}/`, job = request(path + 'refresh', { known_access: await digest(g.access_token) }, g.credential); await entered();
  expect((await request(path + 'forget', {}, g.credential)).status).toBe(200); await control('/release'); expect((await job).status).toBe(401);
  expect((await request(path + 'refresh', { known_access: await digest(g.access_token) }, g.credential)).status).toBe(401);
});
it('expires pending attempts; rejects upstream redirect/failure without exposing bodies or replaying a code', async () => {
  const expired = await begin();
  await runInDurableObject(env.SESSIONS.getByName(expired.attempt), (_instance, state) => {
    state.storage.sql.exec("UPDATE authorization SET value=json_set(value, '$.expires', ?)", Date.now() - 1000);
  });
  await runDurableObjectAlarm(env.SESSIONS.getByName(expired.attempt)); expect((await callback(expired)).status).toBe(401);
  const a = await begin(); await control('/reject');
  const r = await callback(a); expect(r.status).toBe(401); expect(await r.text()).not.toContain('PRIVATE_PROVIDER_BODY');
  expect((await callback(a)).status).toBe(401); expect((await control()).calls).toHaveLength(1);
});
it('rejects browser JSON POST, oversized input and query routing', async () => {
  const r = await exports.default.fetch(new Request(origin + '/v1/attempts', { method: 'POST', headers: { Origin: origin, 'Content-Type': 'application/json' }, body: '{}' })); expect(r.status).toBe(403);
  expect((await request('/v1/attempts', { challenge: 'x'.repeat(5000), state: nativeState })).status).toBe(413);
  expect((await request('/v1/attempts?secret=wrong', {})).status).toBe(404);
});

it('persisted interrupted rotation requires new consent without replay', async () => {
  const g = await authorized(), stub = env.SESSIONS.getByName(g.session), path = `/v1/sessions/${g.session}/refresh`;
  expect((await request(`/v1/sessions/${g.session}/complete`, { verifier })).status).toBe(401);
  await runInDurableObject(stub, (_instance, state) => {
    state.storage.sql.exec("UPDATE authorization SET value=json_set(value, '$.phase', 'refreshing')");
  });
  expect((await request(path, { known_access: await digest(g.access_token) }, g.credential)).status).toBe(401);
  expect((await control()).calls).toHaveLength(1);
});

it('fails closed without service configuration and refuses provider redirects', async () => {
  const unavailable = await worker.fetch(new Request(origin + '/v1/attempts', { method: 'POST' }), { ...env, PUBLIC_ORIGIN: '' });
  expect(unavailable.status).toBe(503);
  const a = await begin(); await control('/redirect');
  expect((await callback(a)).status).toBe(401); expect((await control()).calls).toHaveLength(1);
});

it('rechecks cached recovery ownership after the access-hash await', async () => {
  const g = await authorized(), stub = env.SESSIONS.getByName(g.session);
  await runInDurableObject(stub, instance => {
    const original = Reflect.get(instance, 'accessDigest') as (access: string) => Promise<string>;
    Reflect.set(instance, 'accessDigest', async (access: string) => {
      const response = await fetch('https://fixture-control.test/digest-wait'); await response.body?.cancel();
      return original.call(instance, access);
    });
  });
  // Mismatch selects cached/lost-reply recovery rather than a new rotation.
  const pending = request(`/v1/sessions/${g.session}/refresh`, { known_access: 'z'.repeat(43) }, g.credential);
  await entered();
  expect((await request(`/v1/sessions/${g.session}/forget`, {}, g.credential)).status).toBe(200);
  await control('/release'); expect((await pending).status).toBe(401);
  expect((await control()).calls).toHaveLength(1);
});
