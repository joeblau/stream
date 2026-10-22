// Runs in Miniflare's Node outbound service, never in production or on a network.
let calls: { url: string; authorization: string | null; body: string }[] = [];
let held = false, status = 200;
let release: (() => void) | undefined, digestRelease: (() => void) | undefined;
export async function provider(request: Request): Promise<Response> {
  const u = new URL(request.url);
  if (u.hostname === 'fixture-control.test') {
    if (u.pathname === '/digest-wait') { await new Promise<void>(r => { digestRelease = r; }); return Response.json({ released: true }); }
    if (u.pathname === '/reset') { digestRelease?.(); digestRelease = undefined; release?.(); release = undefined; calls = []; held = false; status = 200; }
    if (u.pathname === '/hold') held = true;
    if (u.pathname === '/release') { digestRelease?.(); digestRelease = undefined; held = false; release?.(); release = undefined; }
    if (u.pathname === '/reject') status = 400;
    if (u.pathname === '/redirect') status = 302;
    return Response.json({ calls, entered: release !== undefined || digestRelease !== undefined });
  }
  if (u.href !== 'https://api.restream.io/oauth/token' || request.method !== 'POST') throw new Error('Unapproved fixture outbound request');
  calls.push({ url: u.href, authorization: request.headers.get('Authorization'), body: await request.text() });
  if (held) await new Promise<void>(r => { release = r; });
  if (status !== 200) return new Response('PRIVATE_PROVIDER_BODY', { status, headers: status === 302 ? { Location: 'https://foreign.example.test/capture' } : {} });
  return Response.json({ access_token: `access-${calls.length}`, refresh_token: `refresh-${calls.length}`, expires_in: 3600, scope: 'chat.read channels.read stream.read' });
}
