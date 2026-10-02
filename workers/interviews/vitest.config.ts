import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';
export default defineConfig({ plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' }, miniflare: { bindings: { OPERATOR_TOKEN: 'test-only-operator-token', TURN_KEY_ID: 'fixture-key', TURN_KEY_API_TOKEN: 'fixture-turn-provider-token', ALLOWED_ORIGIN: 'https://interviews.example.test' } } })] });
