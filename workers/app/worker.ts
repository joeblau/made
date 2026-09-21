// OpenNext generates this module during the build.
// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore -- The module is absent before the first build.
import handler from './.open-next/worker.js';

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const { pathname } = url;
    if (pathname === '/' || pathname.startsWith('/_next/')) {
      return handler.fetch(request, env, ctx);
    }

    // Keep the existing Astro homepage available after OpenNext takes over /.
    if (pathname === '/made' || pathname === '/made/') {
      url.pathname = '/';
      return env.MADE_SITE.fetch(new Request(url, request));
    }

    return env.MADE_SITE.fetch(request);
  },
} satisfies ExportedHandler<CloudflareEnv>;
