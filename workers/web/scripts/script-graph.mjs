/*
 * Classifies the JavaScript Astro emitted into what a visitor actually
 * downloads. Starting from every <script src> and <link rel="modulepreload">
 * in the built HTML, static import edges form the initial (critical) graph;
 * dynamic import() targets and their static closure form the deferred graph.
 * Emitted modules no page reaches (for example the React client entry that
 * @astrojs/react writes even though QR codes render at build time) are
 * reported as unreferenced and never counted as a download.
 */
import { readdir, readFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { gzipSync } from 'node:zlib';

// Minifiers may quote specifiers with backticks, so accept all three quotes.
const STATIC_IMPORT = /(?:^|[^\w$.])(?:import|export)\s*(?:[\w$*{}\s,]+?\s*from\s*)?["'`]([^"'`$]+\.m?js)["'`]/g;
const DYNAMIC_IMPORT = /(?:^|[^\w$.])import\(\s*["'`]([^"'`$]+\.m?js)["'`]\s*\)/g;
const HTML_SCRIPT = /<script\b[^>]*\bsrc="([^"]+)"[^>]*>/gi;
const HTML_PRELOAD = /<link\b[^>]*\brel="modulepreload"[^>]*\bhref="([^"]+)"[^>]*>/gi;

async function filesUnder(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else files.push(path);
  }
  return files;
}

export function sizes(buffer) {
  return { raw: buffer.length, gzip: gzipSync(buffer, { level: 9 }).length };
}

/**
 * @param {string} dist absolute path of Astro's output directory
 * @param {string} base the site's URL base, e.g. "/made"
 * @param {{ compress?: boolean }} options skip gzip when only the graph matters
 */
export async function analyzeScripts(dist, base, { compress = true } = {}) {
  const prefix = `${base.replace(/\/$/, '')}/`;
  const toFile = (url) => {
    const pathname = new URL(url, 'https://site.invalid/').pathname;
    if (!pathname.startsWith(prefix)) throw new Error(`script outside ${prefix}: ${url}`);
    return join(dist, pathname.slice(prefix.length));
  };
  const toUrl = (file) => `${prefix}${relative(dist, file).split('\\').join('/')}`;

  const files = await filesUnder(dist);
  const scripts = files.filter((path) => /\.m?js$/.test(path));
  const sources = new Map();
  for (const file of scripts) sources.set(file, await readFile(file));

  const edges = (file, pattern) => {
    const text = sources.get(file)?.toString('utf8');
    if (text === undefined) throw new Error(`referenced script is missing: ${file}`);
    return [...text.matchAll(pattern)].map(([, specifier]) =>
      toFile(new URL(specifier, `https://site.invalid${toUrl(file)}`).href));
  };
  const closure = (roots, exclude = new Set()) => {
    const seen = new Set();
    const queue = [...roots];
    while (queue.length > 0) {
      const file = queue.pop();
      if (seen.has(file) || exclude.has(file)) continue;
      seen.add(file);
      queue.push(...edges(file, STATIC_IMPORT));
    }
    return seen;
  };

  const entries = new Set();
  for (const html of files.filter((path) => path.endsWith('.html'))) {
    const text = await readFile(html, 'utf8');
    for (const pattern of [HTML_SCRIPT, HTML_PRELOAD]) {
      for (const [, url] of text.matchAll(pattern)) entries.add(toFile(url));
    }
  }
  const initial = closure(entries);
  const dynamicRoots = new Set();
  let frontier = [...initial];
  const deferred = new Set();
  while (frontier.length > 0) {
    for (const file of frontier) for (const target of edges(file, DYNAMIC_IMPORT)) dynamicRoots.add(target);
    const next = closure(dynamicRoots, initial);
    frontier = [...next].filter((file) => !deferred.has(file));
    for (const file of next) deferred.add(file);
  }
  const unreferenced = scripts.filter((file) => !initial.has(file) && !deferred.has(file));

  const describe = (set) => {
    const measure = (buffer) => (compress ? sizes(buffer) : { raw: buffer.length, gzip: 0 });
    const list = [...set].sort().map((file) => ({ url: toUrl(file), ...measure(sources.get(file)) }));
    const total = list.reduce(
      (sum, item) => ({ raw: sum.raw + item.raw, gzip: sum.gzip + item.gzip }),
      { raw: 0, gzip: 0 },
    );
    return { files: list, total };
  };
  return {
    initial: describe(initial),
    deferred: describe(deferred),
    unreferenced: describe(new Set(unreferenced)),
    sourceOf: (url) => sources.get(toFile(url))?.toString('utf8'),
  };
}
