# blau-stream

Next.js App Router + TypeScript, deployed to Cloudflare Workers with
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare/get-started).

Use Node.js 24. Run these commands from `workers/web/`:

```sh
npm ci
cp .dev.vars.example .dev.vars
npm run dev
```

| Command | Purpose |
| --- | --- |
| `npm run dev` | Next.js development server at http://localhost:3000/stream |
| `npm run lint` | ESLint |
| `npm run cf-typegen` | Generate Cloudflare binding types from Wrangler config |
| `npm run typecheck` | Generate Next.js route types and check TypeScript |
| `npm run build:worker` | Build Next.js and the OpenNext Worker bundle |
| `npm run preview` | Build and serve in the local Workers runtime |
| `npm run deploy` | Build and deploy `blau-stream` |

The starter does not require any storage resources. Configure an OpenNext cache
backend before adding ISR or persistent Next.js data caching.

## GitHub Actions

The workflow in `.github/workflows/deploy-web.yml` at the repository root installs
locked dependencies, generates binding types, lints, type-checks, builds, and
validates the Worker bundle on pull requests. Pushes to `main` that change the web
app or workflow also deploy. Manual runs on `main` deploy as well.

Set `CLOUDFLARE_API_TOKEN` as a repository Actions secret, and
`CLOUDFLARE_ACCOUNT_ID` as either a repository Actions secret or variable. The
token needs Workers deployment permissions for that account. The Worker serves `https://blau.app/stream` through the `blau-app` router.
It is built with `basePath: "/stream"`; the router preserves that prefix.
The assets binding runs through OpenNext, and the build moves `_headers`
to the asset root. The workers.dev URL also serves the `/stream` path.

For a local deploy, authenticate first with `npx wrangler login` and verify with
`npx wrangler whoami`, or export the same two Cloudflare environment variables.
Then run `npm run deploy`.
