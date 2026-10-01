# Contributor and coding-agent guide

This file is portable repository context. It does not assume a particular AI
tool, plugin, skill router, or globally installed utility.

## Repository map

- `apple/` — Cockpit (`Pilot`, macOS), Walkie (`Copilot`, iOS), Kneeboard
  (`Plotter`, iPadOS), Trigger (`Wingman`, watchOS),
  shared peer protocols, unit/UI tests, XcodeGen source, and screenshot tools.
- `workers/web/` — Astro static site deployed to Cloudflare.
- `workers/rendezvous/` — Cloudflare Worker and Durable Object relay.
- `docs/` — security models, display policy, binary-artifact provenance, and
  production operations.

## Before changing code

1. Read [README.md](README.md) for the supported Xcode/Bun versions and setup.
2. Read the closest security or operations document for peer, Worker, release,
   credential, or deployment changes.
3. Inspect the current worktree before editing. Preserve unrelated changes.
4. Keep generated files reproducible. Edit `apple/project.yml`, then run the
   pinned `apple/bin/install-xcodegen.sh`; never hand-author project drift.

## Verification contract

Run the smallest relevant checks while iterating and the complete affected
lane before handoff:

```bash
apple/bin/build-ci.sh
apple/bin/test.sh all
apple/bin/lint-swift.sh --all
apple/bin/app-icon-tool.swift validate
bun run ci
bin/check-docs.sh
```

CI runs Apple work on Xcode 26 and Worker work from the frozen Bun lockfile.
Avoid new unpinned network downloads or Actions. A generated artifact must have
one authoritative source, a checked-in regeneration path, and a validation
step.

## Repository conventions

- Swift 6 concurrency checking is enabled. Keep UI state on the main actor and
  make ownership/cancellation explicit for long-lived tasks.
- Treat all peer, WebSocket, Bonjour, pasteboard, browser-message, subprocess,
  and file inputs as untrusted. Enforce size/lifetime/replay bounds before
  allocation or state mutation.
- Do not weaken pairing, authentication, content security policy, signing, or
  CI checks to make a test pass.
- Do not commit secrets, `.dev.vars`, local `.env` files, signing material,
  derived data, release symbols, or generated dependency caches.
- Keep GitHub issue references stable; do not document source line numbers that
  become stale as files move.

## Handoff

Summarize behavior changes, files with non-obvious policy decisions, commands
run, and checks that could not run. Deployment, release publication, repository
settings, and destructive history migration require explicit maintainer scope.
