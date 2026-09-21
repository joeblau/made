# blau.app

Next.js with the OpenNext Cloudflare adapter. The homepage at `https://blau.app/`
says **Hello world**. Bun manages dependencies and build scripts; production
runs in Cloudflare's Workers runtime.

From the repository root:

```bash
bun install --frozen-lockfile
bun run --cwd workers/app dev
bun run --cwd workers/app check
bun run --cwd workers/app build
bun run --cwd workers/app preview
```

`dev` serves Next.js at `http://localhost:3000`. `preview` serves the built
Worker at `http://localhost:8787`. Build before previewing or deploying.

The `blau-app` Worker uses the `blau.app/*` route in front of the existing
`blau-web` Custom Domain. `/` (including query strings) and `/_next/` go to
OpenNext. `/made` and `/made/` serve the Astro Worker's homepage. All other paths
go to the existing Astro Worker unchanged using the `MADE_SITE` service binding.
Keep `blau-web` deployed;
the two Workers do not compete for ownership of the Custom Domain.

To preview both sites locally, run the Astro Worker in a second terminal from
the repository root; Wrangler connects the local service binding automatically:

```bash
bun run --cwd workers/web build
cd workers/web
bunx --no-install wrangler dev --port 8788
```

Deploy with Cloudflare credentials for the account containing the `blau.app`
zone and the existing `blau-web` Worker:

```bash
bun run --cwd workers/app build
bun run --cwd workers/app deploy
```

In addition to **Workers Scripts: Write**, this Worker's route needs
**Workers Routes: Write** and **Zone: Read**, restricted to the `blau.app` zone.
The existing Astro and rendezvous workers continue to use their Custom Domains.

The setup follows the [OpenNext Cloudflare guide](https://opennext.js.org/cloudflare/get-started)
and its [custom Worker support](https://opennext.js.org/cloudflare/howtos/custom-worker).
