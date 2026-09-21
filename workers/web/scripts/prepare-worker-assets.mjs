import { cp, mkdir, rename, rm } from 'node:fs/promises';

const dist = new URL('../dist/', import.meta.url);
const assets = new URL('../.worker-assets/', import.meta.url);

// Only this generated directory is replaced. Astro's base changes emitted URLs,
// not the on-disk layout; Static Assets needs the prefix in the layout as well.
await rm(assets, { recursive: true, force: true });
await mkdir(assets, { recursive: true });
await cp(dist, new URL('made/', assets), { recursive: true });
// Cloudflare reads _headers at the asset root, with /made-prefixed patterns.
await rename(new URL('made/_headers', assets), new URL('_headers', assets));
console.log('Prepared web-made assets under /made');
