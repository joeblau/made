# Production operations

## Required GitHub configuration

The `production` environment owns the web and rendezvous Cloudflare deploy
jobs. Protect it with required reviewers if deployments should pause for approval, and store these
environment secrets there:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`

The token should be an account-scoped custom token limited to the blau account
with **Workers Scripts: Write**. The Workers Custom Domains API accepts that
permission for attaching `rendezvous.blau.app`. The child `web-made` has no
Custom Domain. The separately maintained OpenNext
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
deploys both services. The workflow is serialized so two production deploys
cannot race.

To inspect or roll back a service locally with the same pinned CLI:

```bash
bun install --frozen-lockfile
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

## MADE mount and parent ownership

`workers/web` deploys the internal `web-made` Worker. It has no Custom Domain,
zone route, workers.dev endpoint, or preview URL. The independently deployed
`blau-app` parent in [joeblau/blau](https://github.com/joeblau/blau) owns
`blau.app` and binds `MADE` to `web-made` in the same Cloudflare account.
Do not add a Worker in this repository that claims `blau.app`; that would
overwrite the parent site.

The parent forwards only `/made` and `/made/*` with the full incoming request
unchanged. `/made-up` and all other routes stay on OpenNext. Astro's
`base: '/made'` prefixes generated bundles and fonts; the layout uses the base
for its favicon and social images. `prepare-worker-assets.mjs` copies `dist/`
into `.worker-assets/made/` and places `_headers` at the asset root. This lets
Cloudflare Static Assets serve the original `/made` URL, including its own
redirects and 404s, without a prefix-stripping Worker. The generated asset tree
is cached by Turborepo and verified by `test/mount.test.mjs`.

### Local development

Use `bun run --cwd workers/web dev` for Astro at `http://localhost:4321/made`.
For the real Service Binding, start the built child:

```bash
bun run --cwd workers/web build
bun run --cwd workers/web preview:worker
```

In the parent repository, run `bun run build`, then
`bun run preview -- --port 8787`. Wrangler connects to the local child on port
8788 by its `web-made` name. Visit `http://localhost:8787/made` through the
parent. Plain Next.js dev does not run the parent's Worker router.

### First deployment and migration

1. Verify the child build and tests; deploy this repository's `web` job first.
   It must create `web-made` in the same account used by the parent.
2. Deploy the parent from `joeblau/blau`. Its Action checks for `web-made`
   before deployment. Both repositories need their own Cloudflare credentials.
3. Transfer the existing `blau.app` Custom Domain from legacy `blau-web` to
   `blau-app` as declared by the parent config. If Wrangler reports an existing
   owner, complete the transfer in Cloudflare and rerun the parent deployment.
   Retain the parent's `blau.app/*` route. Do not assign this domain to `web-made`.
4. Check the public endpoints above, plus `/made/favicon.svg`, `/made/og.jpg`,
   and a real `/made/_astro/` bundle. `/made-up` must return the parent 404;
   `/made/_astro/example.js` should return the child 404 if that file is absent.

The original blockers were the child's `blau-web` deployment name, its apex
domain claim, root asset URLs, and the competing parent deploy job. These must
all be replaced before the parent binding is published. Keep legacy `blau-web`
available until verification completes. A parent rollback can restore the old
binding; Worker version rollback does not restore Custom Domain ownership.

See [HTTP Service Bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/http/)
and [Astro base](https://docs.astro.build/en/reference/configuration-reference/#base).

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
