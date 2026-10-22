import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';
import { provider } from './test/provider-fixture.ts';
export default defineConfig({ plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' }, miniflare: { outboundService: provider, bindings: { PUBLIC_ORIGIN: 'https://broker.example.test', RESTREAM_CLIENT_ID: 'fixture-client', RESTREAM_CLIENT_SECRET: 'fixture-server-secret' } } })] });
