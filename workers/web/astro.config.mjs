import react from '@astrojs/react';
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://blau.app',
  base: '/made',
  // React renders the QR codes at build time only; no client directives are
  // used, so no React runtime ships to the browser.
  integrations: [react()],
  // The CSP in public/_headers forbids inline styles, so always emit external CSS.
  build: { inlineStylesheets: 'never' },
  vite: {
    build: {
      // The CSP also forbids inline scripts, so never inline small bundles.
      assetsInlineLimit: 0,
      // The deferred cockpit scene (Three.js) is one ~535 KB chunk by design.
      // scripts/check-build-size.mjs enforces separate initial and deferred
      // JavaScript budgets, so Vite's generic warning only adds noise.
      chunkSizeWarningLimit: 600,
    },
  },
});
