# Stream

Stream's Apple apps and web app share this repository.

| Directory | Contents |
| --- | --- |
| [`apple/`](apple/README.md) | iOS and macOS apps, shared Swift code, tests, XcodeGen project, and HaishinKit submodule |
| [`workers/web/`](workers/web/README.md) | `blau-stream`, a Next.js app deployed to Cloudflare Workers with OpenNext |

## Apple apps

```sh
git submodule update --init --recursive
cd apple
xcodegen generate
open Stream.xcodeproj
```

From the repository root, `bun stream` still builds, installs, and launches the
iOS app on a paired iPhone. See [Apple app documentation](apple/README.md) for
requirements and configuration.

## Web app

Use Node.js 24 and npm:

```sh
cd workers/web
npm ci
npm run dev
```

The app runs at http://localhost:3000. Run `npm run preview` to build and test it
in the local Cloudflare Workers runtime.

## Deployment

Set these GitHub repository Actions secrets:

- `CLOUDFLARE_ACCOUNT_ID` (an Actions variable with the same name also works).
- `CLOUDFLARE_API_TOKEN` with permission to deploy Workers to that account.

The [web workflow](.github/workflows/deploy-web.yml) checks pull requests and
deploys `blau-stream` when web files change on `main`. It can also be run manually
on `main`. Apple CI runs from `apple/`.
