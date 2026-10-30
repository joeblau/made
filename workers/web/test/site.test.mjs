import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built landing page renders every product section and download', async () => {
  const html = await readFile(`${dist}made/index.html`, 'utf8');
  const homepage = await readFile(`${dist}index.html`, 'utf8');
  assert.equal(homepage, html, 'the homepage serves the same landing page');
  assert.match(html, /<link rel="canonical" href="https:\/\/blau\.app\/made">/);
  assert.match(html, /<meta property="og:url" content="https:\/\/blau\.app\/made">/);
  assert.match(html, /<title>made — One cockpit for every agent<\/title>/);
  assert.match(html, /<meta property="og:image" content="https:\/\/blau\.app\/made\/og\.jpg">/);
  assert.match(html, /<meta name="twitter:card" content="summary_large_image">/);
  assert.ok((await stat(`${dist}og.jpg`)).size > 0, 'og.jpg ships in dist');
  assert.match(html, /<section class="hero" id="top" aria-labelledby="page-title" data-hero>/);
  assert.match(html, /<div class="cockpit-bg" aria-hidden="true">/);
  assert.match(html, /<canvas data-cockpit-scene>/);
  assert.match(html, /<canvas data-cockpit-hud>/);
  assert.match(html, /<h1 id="page-title">/);
  assert.match(html, /Every agent\./);
  assert.match(html, /MULTIMODAL AGENTIC DEVELOPMENT ENVIRONMENT/);
  for (const id of ['workflows', 'capabilities', 'companions', 'security', 'download']) {
    assert.match(html, new RegExp(`id="${id}"`), `missing #${id}`);
  }
  assert.match(html, /IPHONE \/ WALKIE/);
  assert.match(html, /WATCH \/ TRIGGER/);
  assert.match(html, /IPAD \/ KNEEBOARD/);
  assert.match(html, />Download for macOS<\/span>/);
  assert.match(html, />Download for iOS<\/span>/);
  assert.match(html, />Download for iPad<\/span>/);
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/Q2G2q5ts"/);
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/NsVkk4Rq"/);
  assert.match(html, /<dialog class="qr-dialog" data-qr-dialog/);
  assert.equal((html.match(/data-qr-code="/g) ?? []).length, 2);
  assert.equal((html.match(/<title>QR Code<\/title>/g) ?? []).length, 2);
  assert.match(html, /href="https:\/\/github\.com\/joeblau\/made"/);
  assert.match(html, /href="https:\/\/x\.com\/joeblau"/);
  assert.match(html, /href="https:\/\/github\.com\/joeblau\/made\/releases\/latest"/);
  assert.match(html, /macOS 26\+/);
  assert.match(html, /data-theme-toggle/);
  assert.match(html, /src="\/made\/theme-init\.js"/);
  assert.equal((html.match(/data-theme-picture/g) ?? []).length, 15, 'desktop and mobile product images follow the selected theme');
  assert.equal((html.match(/data-appearance="dark"/g) ?? []).length, 15);
  assert.doesNotMatch(html, /title="Coming soon"/);
});

test('every selected native capture ships in both appearances', async () => {
  const scenes = ['workspace', 'editor', 'browser', 'device', 'actions', 'runners', 'agentic-use', 'docker', 'remote-desktop', 'tasks'];
  for (const scene of scenes) {
    for (const appearance of ['light', 'dark']) {
      const path = `${dist}screenshots/cockpit/cockpit-${scene}-${appearance}.png`;
      assert.ok((await stat(path)).size > 100_000, `${scene} ${appearance} ships as a real capture`);
    }
  }
});

test('the built landing page keeps CSP-compatible output', async () => {
  const html = await readFile(`${dist}made/index.html`, 'utf8');
  assert.doesNotMatch(html, /<style\b/i);
  assert.doesNotMatch(html, /\sstyle\s*=/i);
  assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
  const scriptTags = html.match(/<script\b[^>]*>/gi) ?? [];
  assert.ok(scriptTags.length >= 3);
  for (const tag of scriptTags) {
    const source = tag.match(/\bsrc="([^"]+)"/);
    assert.ok(source?.[1].startsWith('/made/'), `script must be external and same-origin: ${tag}`);
  }
});

test('the stylesheet serves both color schemes without decorative strokes', async () => {
  const html = await readFile(`${dist}made/index.html`, 'utf8');
  const hrefs = [...html.matchAll(/<link rel="stylesheet" href="(\/made\/_astro\/[^"]+\.css)">/g)].map((m) => m[1]);
  assert.ok(hrefs.length > 0, 'the page links at least one external stylesheet');
  const css = (await Promise.all(hrefs.map((href) => readFile(`${dist}${href.slice('/made/'.length)}`, 'utf8')))).join('\n');
  assert.match(css, /color-scheme:\s*light dark/, 'the root opts into both schemes');
  assert.match(css, /light-dark\(/, 'semantic tokens resolve per scheme');
  assert.doesNotMatch(css, /border(?:-(?:top|right|bottom|left|color|width))?:\s*(?!0\b|none)[^;}]*/, 'no element draws a border');
  assert.match(html, /<meta name="theme-color" data-theme-color="light" media="\(prefers-color-scheme: light\)"/);
  assert.match(html, /<meta name="theme-color" data-theme-color="dark" media="\(prefers-color-scheme: dark\)"/);
});

test('Three.js and optional interactions stay out of the critical script graph', async () => {
  const { analyzeScripts } = await import('../scripts/script-graph.mjs');
  const graph = await analyzeScripts(dist, '/made', { compress: false });
  assert.ok(graph.initial.files.length >= 4, 'theme, site, and cockpit bootstraps are initial');
  assert.ok(graph.initial.files.some(({ url }) => url === '/made/theme-init.js'));
  for (const { url } of graph.initial.files) {
    assert.ok(url.startsWith('/made/_astro/') || url === '/made/theme-init.js');
    assert.doesNotMatch(graph.sourceOf(url), /THREE\.WebGLRenderer/, `${url} must not bundle Three.js`);
  }
  const scene = graph.deferred.files.filter(({ url }) => /THREE\.WebGLRenderer/.test(graph.sourceOf(url)));
  assert.equal(scene.length, 1, 'exactly one deferred chunk carries the cockpit scene');
  assert.match(scene[0].url, /^\/made\/_astro\/f35-cockpit\.[\w-]+\.js$/);
  assert.ok(graph.deferred.files.some(({ url }) => /\/interactions\.[\w-]+\.js$/.test(url)));
  for (const page of ['index.html', 'made/index.html']) {
    const html = await readFile(`${dist}${page}`, 'utf8');
    assert.ok(!html.includes(scene[0].url), `${page} never preloads the scene`);
  }
});
