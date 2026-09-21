import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built landing page renders the download slate', async () => {
  const html = await readFile(`${dist}made/index.html`, 'utf8');
  const homepage = await readFile(`${dist}index.html`, 'utf8');
  assert.equal(homepage, html, 'the homepage serves the same landing page');
  assert.match(html, /<link rel="canonical" href="https:\/\/blau\.app\/made">/);
  assert.match(html, /<meta property="og:url" content="https:\/\/blau\.app\/made">/);
  assert.match(html, /<title>made<\/title>/);
  assert.match(html, /<meta property="og:image" content="https:\/\/blau\.app\/made\/og\.jpg">/);
  assert.match(html, /<meta name="twitter:card" content="summary_large_image">/);
  assert.ok((await stat(`${dist}og.jpg`)).size > 0, 'og.jpg ships in dist');
  assert.match(html, /<section class="landing" aria-labelledby="page-title">/);
  assert.match(html, /<div class="cockpit-bg" aria-hidden="true">/);
  assert.match(html, /<canvas data-cockpit-scene>/);
  assert.match(html, /<canvas data-cockpit-hud>/);
  assert.match(html, /<h1 id="page-title">made<\/h1>/);
  assert.match(html, /<p class="landing__tagline">Multimodal Agentic Development Environment<\/p>/);
  assert.match(html, /<h2>made<\/h2>/);
  assert.match(html, /<h2>Walkie\/Trigger<\/h2>/);
  assert.match(html, /<h2>Kneeboard<\/h2>/);
  assert.match(html, />Download for macOS<\/span>/);
  assert.match(html, />Download for iOS<\/span>/);
  assert.match(html, />Download for iPad<\/span>/);
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/Q2G2q5ts"/);
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/NsVkk4Rq"/);
  assert.match(html, /<dialog class="qr-dialog" data-qr-dialog>/);
  assert.equal((html.match(/data-qr-code="/g) ?? []).length, 2);
  assert.equal((html.match(/<title>QR Code<\/title>/g) ?? []).length, 2);
  assert.match(html, /href="https:\/\/github\.com\/joeblau\/made"/);
  assert.match(html, /href="https:\/\/x\.com\/joeblau"/);
  assert.equal((html.match(/title="Coming soon"/g) ?? []).length, 1);
});

test('the built landing page keeps CSP-compatible output', async () => {
  const html = await readFile(`${dist}made/index.html`, 'utf8');
  assert.doesNotMatch(html, /<style\b/i);
  assert.doesNotMatch(html, /\sstyle\s*=/i);
  assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
  const scriptTags = html.match(/<script\b[^>]*>/gi) ?? [];
  for (const tag of scriptTags) {
    assert.match(tag, /\bsrc="\/made\/_astro\//, `script must be an external bundle: ${tag}`);
  }
});

test('the stylesheet serves both color schemes without decorative strokes', async () => {
  const html = await readFile(`${dist}made/index.html`, 'utf8');
  const hrefs = [...html.matchAll(/<link rel="stylesheet" href="(\/made\/_astro\/[^"]+\.css)">/g)].map((m) => m[1]);
  assert.ok(hrefs.length > 0, 'the page links at least one external stylesheet');
  const css = (await Promise.all(hrefs.map((href) => readFile(`${dist}${href.slice("/made/".length)}`, 'utf8')))).join('\n');
  assert.match(css, /color-scheme:\s*light dark/, 'the root opts into both schemes');
  assert.match(css, /light-dark\(/, 'semantic tokens resolve per scheme');
  assert.doesNotMatch(css, /border(?:-(?:top|right|bottom|left|color|width))?:\s*(?!0\b|none)[^;}]*/, 'no element draws a border');
  assert.match(html, /<meta name="theme-color" media="\(prefers-color-scheme: light\)"/);
  assert.match(html, /<meta name="theme-color" media="\(prefers-color-scheme: dark\)"/);
});
