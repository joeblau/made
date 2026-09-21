# Production operations

## Required GitHub configuration

The `production` environment owns all three Cloudflare deploy jobs. Protect it with
required reviewers if deployments should pause for approval, and store these
environment secrets there:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`

The token should be an account-scoped custom token limited to the blau account
with **Workers Scripts: Write**. The Workers Custom Domains API accepts that
permission for attaching `blau.app` and `rendezvous.blau.app`. The OpenNext
`blau-app` Worker additionally requires **Workers Routes: Write** and
**Zone: Read**, restricted to the `blau.app` zone, for its `blau.app/*` route.
No DNS write, account administration, KV, R2, or user permissions are needed.
Rotate the token if its scope is broader and confirm all
jobs still deploy before deleting the old token.

All Actions and build tools are pinned. Dependabot proposes weekly Bun-workspace
and GitHub Actions updates, which must pass the same CI gates before merge.

## Deploy and rollback

Pushes to `main` run all Worker quality gates, then deploy only the changed
service with the lockfile-installed Wrangler. A manual Deploy workflow run
deploys all three services. The workflow is serialized so two production deploys
cannot race.

To inspect or roll back a service locally with the same pinned CLI:

```bash
bun install --frozen-lockfile
bun run --cwd workers/app deploy:list
bun run --cwd workers/app rollback -- <VERSION_ID>
bun run --cwd workers/web deploy:list
bun run --cwd workers/web rollback -- <VERSION_ID>
bun run --cwd workers/rendezvous deploy:list
bun run --cwd workers/rendezvous rollback -- <VERSION_ID>
```

After a deploy, verify the public endpoints:

```bash
curl --fail --silent --show-error https://rendezvous.blau.app/healthz
curl --fail --silent --show-error https://blau.app/
curl --fail --silent --show-error --location --head https://blau.app/made
```

The Astro site response at `/made` must include its CSP, `nosniff`, `DENY`, referrer policy,
permissions policy, COOP, and HSTS headers. The build checks the same policy and
rejects inline scripts, inline styles, and event handlers before deployment.

The OpenNext Worker serves `/` and `/_next/`. `/made` and `/made/` serve the
Astro homepage; other paths are forwarded unchanged to `blau-web` through its
`MADE_SITE` service binding. Keep the existing Astro
Worker and its apex Custom Domain deployed. See the
[OpenNext setup guide](../workers/app/README.md) for local preview and deployment.

## HSTS decision

`blau.app` sends a two-year HSTS policy with `includeSubDomains` because the
apex and `rendezvous.blau.app` are HTTPS-only Cloudflare Custom Domains. It is
deliberately not submitted for browser preload: that remains a separate,
explicit operational decision. Do not introduce an HTTP-only subdomain.

For an emergency policy rollback, deploy
`Strict-Transport-Security: max-age=0` over valid HTTPS. Browsers that already
cached HSTS still require a valid HTTPS response to receive the rollback, so
certificate continuity is part of the recovery plan.

## Rendezvous privacy and abuse controls

Clients generate pairing tokens and room identifiers from at least 192 random
bits, encoded as base64url. Tokens and public keys are accepted only in POST
bodies and never query strings. Production trusts only `CF-Connecting-IP` as
the source address; localhost HTTP and missing edge headers are available only
under the explicit development environment.

Rate-limit keys are SHA-256 digests. Analytics Engine receives only an aggregate
event name and count—never an IP address, pairing token, public key, endpoint,
or relay payload. WebSocket rooms allow two peers and enforce message size,
message rate, backpressure, idle, and absolute-lifetime limits.
