# Self-hosted CI runners

All jobs in this repository's `.github/workflows` require self-hosted runners.
There is no GitHub-hosted fallback. Register runners with access to
`joeblau/stream` before enabling these workflows; jobs remain queued when no
matching runner is available.

## Runner pools

Keep the default `self-hosted`, operating-system and architecture labels when
registering a runner. Add the custom macOS label that describes its environment:

| Environment | Required labels | Used for |
| --- | --- | --- |
| macOS 26, Apple Silicon | `self-hosted`, `macOS`, `ARM64`, `macos-26` | Native ARM builds, iOS Simulator, native fixtures |
| macOS 26, Intel | `self-hosted`, `macOS`, `X64`, `macos-26-intel` | Native Intel builds and fixtures |
| macOS 15, Apple Silicon | `self-hosted`, `macOS`, `ARM64`, `macos-15` | Older-macOS fixtures and Stream Deck packaging |
| Linux, x86-64 | `self-hosted`, `Linux`, `X64` | Web, interview, and authorization-broker jobs |

The macOS matrix values are now custom self-hosted labels. Assign them only to
machines with the indicated OS and native architecture; do not assign both
`macos-26` and `macos-26-intel` to a machine. Matrix job and artifact names stay
the same to preserve architecture-specific results.

## Provisioning

- Install a current GitHub Actions runner and Git. Allow access to GitHub,
  package registries, Homebrew, and the services used by deployment jobs.
- On macOS, install and select full Xcode, accept its license, and complete
  first-launch setup. macOS 26 jobs need Xcode 26 or later. The simulator job
  needs an available iPhone 17 simulator and its iOS runtime. Install Homebrew
  with writable directories for the runner account and expose it on `PATH`.
  Workflows install XcodeGen, CMake, FFmpeg, and libvpx as needed. Run native
  UI/media fixtures in an appropriate logged-in desktop session; their existing
  capability and permission checks must pass.
- On Linux, provide a supported Ubuntu environment with the runtime libraries
  needed by Node.js, Cloudflare tooling, and Chrome. Node.js and Chrome are
  installed by the workflow actions. The runner account must be able to write
  the tool cache and install the workflow's global npm version.
- Retain the existing repository deployment secrets. Runner migration does
  not change deployment conditions or credentials.

Prefer disposable runners with a clean machine environment for every job,
especially for pull requests. For persistent machines, use dedicated CI
accounts, keep one active runner per native test environment, and reset
job-created processes, simulator state, and temporary files between jobs.
Checkout cleans the repository, but not machine-wide state. Native tests use
local ports and shared OS services, so concurrent runner processes on one
machine can interfere with each other.

## Verification

List registered environments with:

```sh
gh api repos/joeblau/stream/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
actionlint
```

After registration, run the relevant workflows and verify both native
architectures, the older macOS fixtures, the simulator, and Linux jobs. Local
workflow linting cannot validate machine provisioning or native capabilities.

See GitHub's [self-hosted runner routing documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)
for label matching and runner registration guidance. Workflows inside the
vendored `apple/Vendor/HaishinKit.swift` submodule belong to its upstream
repository and are not executed as this repository's workflows.

The owned scene LaunchServices diagnostic requires `GITHUB_ACTIONS=true` and
`RUNNER_ENVIRONMENT=self-hosted` at all three entry points (shell runner, native
launcher, and fixture app). Its identity, deadline, keyboard calibration, and
native-exit checks remain mandatory. Historical hosted results in the scene
protocol documents do not qualify the new self-hosted environment.
