# blau

blau is a native Apple development cockpit: four companion apps, a public web
site, and an optional rendezvous relay.

- **Cockpit** (macOS, internal target `Pilot`) combines terminals, editing, browser previews, GitHub work,
  device capture, simulators, remote screens, and local container control (see
  [the Docker section](docs/docker-section.md)).
- **Walkie** (iOS, internal target `Copilot`) supplies a trackpad, voice transcription, settings, and
  secure peer messaging.
- **Kneeboard** (iPadOS, internal target `Plotter`) mirrors a Cockpit window with low-latency HEVC and sends
  normalized PencilKit annotations. It supports rotation, Split View, and
  Stage Manager; see [the display policy](docs/plotter-display-policy.md).
- **Trigger** (watchOS, internal target `Wingman`) sends live, short-lived terminal control gestures
  through its paired Walkie.
- **App** is the Bun-managed Next.js/OpenNext Worker at [blau.app](https://blau.app),
  initially showing “Hello world”. See [its setup guide](workers/app/README.md).
- **Web** is the static Astro site at [blau.app/made](https://blau.app/made).
- **Rendezvous** is a Cloudflare Durable Object WebSocket relay for encrypted
  peers that cannot discover one another locally. It cannot read peer payloads.

The peer trust, verification-code, encryption, replay, and framing design is
documented in [device pairing and FrameLink](docs/device-pairing-and-framelink.md)
and [secure messaging](docs/p2p-secure-messaging.md).

## Prerequisites

- macOS with **Xcode 26.x** selected by `xcode-select` (the version enforced in
  CI). Xcode 27 previews are not the supported release toolchain.
- [Homebrew](https://brew.sh/) for the Apple command-line tool set, including
  Fastlane for reproducible screenshot capture.
- Git LFS. Current checkouts download GhosttyKit through SwiftPM, while
  historical revisions still contain LFS pointers; keeping LFS installed makes
  bisects and old release checkouts work.
- [Bun 1.3.14](https://bun.sh/) (pinned by `packageManager`) for all Worker and
  web dependencies.
- A Cloudflare account only when running or deploying the Worker services.

XcodeGen is downloaded at a pinned version and checksum by the repository; do
not rely on an arbitrary global installation.

## Clean-checkout setup

```bash
git clone https://github.com/joeblau/blau.git
cd blau
git lfs install
git lfs pull

bun install --frozen-lockfile
brew bundle --file apple/Brewfile
apple/bin/install-xcodegen.sh generate --spec apple/project.yml --project apple
xcodebuild -resolvePackageDependencies -project apple/blau.xcodeproj
open apple/blau.xcodeproj
```

SwiftPM verifies the checksummed GhosttyKit release artifact declared by the
local package in `apple/Packages/GhosttyKit`. Maintainers can reproduce and
audit that binary with [the GhosttyKit release procedure](docs/ghosttykit.md).

## Build and verify

Run these from the repository root:

```bash
# Apple project, application builds, tests, lint, and generated assets
apple/bin/install-xcodegen.sh generate --spec apple/project.yml --project apple
apple/bin/build-ci.sh
apple/bin/test.sh all
apple/bin/lint-swift.sh --all
apple/bin/app-icon-tool.swift validate

# Web + rendezvous dependencies, lint, type/metadata checks, tests, build, audit
bun install --frozen-lockfile
bun run lint
bun run check
bun run test
bun run build
bun run audit
bun run ci

# Documentation links and repository paths
bin/check-docs.sh
```

`apple/bin/test.sh pilot` runs only the macOS suite and
`apple/bin/test.sh shared` runs only the iOS Simulator suite. Set
`IOS_SIMULATOR_UDID` to select an installed iPhone simulator. The scripts pin
`Package.resolved`, disable signing, and isolate derived data.

To lint only a branch diff, run
`apple/bin/lint-swift.sh --changed origin/main`. Suppress a SwiftLint rule only
at the narrowest declaration and explain why; do not grow the baseline.

## Local development and screenshots

```bash
# Build, install, and launch the desktop, phone, and tablet apps
bun cockpit
bun walkie
bun kneeboard

# Next.js, Astro, and rendezvous development servers through Turborepo
bun run dev

# A single service
bun run --cwd workers/app dev
bun run --cwd workers/web dev
bun run --cwd workers/rendezvous dev

# Demo-mode product screenshots
cd apple
fastlane snapshotAll
./bin/capture-pilot.sh
./bin/capture-wingman.sh
```

`bun walkie` selects an available physical iPhone, and `bun kneeboard` selects
an available physical iPad. Connect and unlock the device, enable Developer
Mode, and let Xcode manage development signing. If multiple matching devices
are connected, select one with `--device`, for example
`bun kneeboard --device "My iPad"`. Set `BLAU_IOS_DEVICE` for the equivalent
non-interactive selection.

The screenshot harness uses deterministic demo state and writes to
`workers/web/public/screenshots/`. It never requires a live peer.

## Deployment and secrets

Production deployment and rollback are owned by the protected GitHub
`production` environment and the pinned workflows. See
[production operations](docs/operations.md) for the exact commands, Cloudflare
token scope, endpoint verification, and rollback procedure. Tagged macOS and
TestFlight builds use the separate protected `apple-release` environment; see
[Apple releases](docs/apple-releases.md) for the signing material, App Store
Connect setup, tag convention, and release behavior.

For an authorized manual deployment using the lockfile-installed Wrangler:

```bash
bun run --cwd workers/web deploy
bun run --cwd workers/rendezvous deploy
```

Never commit credentials, local `.env` files, signing material, pairing keys,
or Cloudflare tokens. Local Worker values belong in untracked `.dev.vars`
files. Production values belong in the GitHub `production` environment or
Cloudflare's encrypted secret store. Xcode signing is configured by the local
developer account, not checked-in certificates.

## Security

Cockpit Notes is a local plaintext scratchpad. Its value masking is only a visual
shoulder-surfing aid; it is not encryption or a password manager.

Please report vulnerabilities privately using the process in
[SECURITY.md](SECURITY.md). Do not open a public issue for an unpatched
security problem.

## Contributing

Generated Xcode project changes must match `apple/project.yml`; CI regenerates
the project and rejects drift. Use [CLAUDE.md](CLAUDE.md) as portable repository
guidance for contributors and coding agents. Work is tracked in
[GitHub Issues](https://github.com/joeblau/blau/issues), not by adding stale
source line references to [TODOS.md](TODOS.md).

## Optional Chromium browser

Cockpit's Chromium-backed browser panel is opt-in; clean Debug and Release builds continue to use WebKit without downloading CEF. Validate the immutable artifact lock with `bash apple/bin/package-chromiumkit.sh manifest`, then follow the [Chromium browser guide](docs/chromium-browser.md) and [ChromiumKit setup](apple/Packages/ChromiumKit/README.md) to install, build, run `apple/bin/test-chromium-runtime.sh`, sign, and validate the Chromium configuration.
