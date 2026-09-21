import { readFile, readdir, stat } from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';

const assets = new URL('../.worker-assets/', import.meta.url);

test('the deployable asset tree serves pages and every local asset under /made', async () => {
  assert.deepEqual((await readdir(assets)).sort(), ['_headers', 'made']);
  const html = await readFile(new URL('made/index.html', assets), 'utf8');
  const urls = [...html.matchAll(/(?:src|href|content)="([^"\s]+)"/g)]
    .map((match) => match[1])
    .filter((value) => value.startsWith('/') || value.startsWith('https://blau.app/'));
  assert.ok(urls.length > 3, 'checks emitted scripts, CSS, favicon, and metadata');
  for (const value of urls) {
    const url = new URL(value, 'https://blau.app');
    assert.equal(url.origin, 'https://blau.app');
    assert.ok(url.pathname === '/made' || url.pathname.startsWith('/made/'), value);
    const path = url.pathname === '/made' ? '/made/index.html' : url.pathname;
    assert.ok((await stat(new URL(path.slice(1), assets))).size > 0, value);
  }
  const stylesheets = urls.filter((url) => url.endsWith('.css'));
  assert.ok(stylesheets.length > 0);
  let fonts = 0;
  for (const stylesheet of stylesheets) {
    const css = await readFile(new URL(stylesheet.slice(1), assets), 'utf8');
    for (const [, value] of css.matchAll(/url\(["']?([^"')]+)["']?\)/g)) {
      if (value.startsWith('data:')) continue;
      const url = new URL(value, `https://blau.app${stylesheet}`);
      assert.ok(url.pathname.startsWith('/made/'), value);
      assert.ok((await stat(new URL(url.pathname.slice(1), assets))).size > 0, value);
      if (url.pathname.endsWith('.woff2')) fonts++;
    }
  }
  assert.ok(fonts > 0, 'bundled fonts remain under /made');
  const headers = await readFile(new URL('_headers', assets), 'utf8');
  assert.match(headers, /\/made\/_astro\/\*\n\s+Cache-Control: public, max-age=31536000, immutable/);
  assert.match(headers, /Content-Security-Policy:/);
});
