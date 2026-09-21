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
    },
  },
});
