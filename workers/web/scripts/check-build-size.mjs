/*
 * Build budgets for what a visitor downloads. JavaScript is split by the
 * module graph the built HTML actually references (see script-graph.mjs):
 *
 *   initial  - <script src>/modulepreload entries and their static imports.
 *              This is the critical path for the download slate and must stay
 *              free of Three.js. Measured at 3,404 raw / 1,714 gzip bytes
 *              with the deferred scene and its controller (#269, #270).
 *   deferred - dynamic import() chunks, i.e. the decorative cockpit scene
 *              fetched after load. Measured at 536,586 raw / 134,452 gzip.
 *
 * Thresholds leave roughly 10-15% headroom over those measurements (raw and
 * gzip -9 are both enforced). Modules no page references are reported but not
 * counted. Raise a budget only with a fresh measurement in the commit.
 */
import { readdir, stat } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeScripts } from './script-graph.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist');
const base = '/made';

const budgets = {
  css: { raw: 35_000 },
  initialScripts: { raw: 8_000, gzip: 4_000 },
  deferredScripts: { raw: 600_000, gzip: 150_000 },
};

async function filesUnder(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else files.push(path);
  }
  return files;
}

const css = (await filesUnder(dist)).filter((path) => extname(path) === '.css');
const cssBytes = (await Promise.all(css.map((path) => stat(path))))
  .reduce((sum, item) => sum + item.size, 0);
const scripts = await analyzeScripts(dist, base);

const results = [
  ['CSS', { raw: cssBytes }, budgets.css],
  ['initial JS', scripts.initial.total, budgets.initialScripts],
  ['deferred JS', scripts.deferred.total, budgets.deferredScripts],
];

let failed = false;
for (const [label, measured, budget] of results) {
  const over = Object.entries(budget).filter(([kind, limit]) => measured[kind] > limit);
  const summary = Object.keys(budget).map((kind) => `${kind} ${measured[kind]}/${budget[kind]}`).join(', ');
  if (over.length > 0) {
    failed = true;
    console.error(`Web build budget failed: ${label} ${summary}`);
  } else {
    console.log(`Web build budget: ${label} ${summary} bytes`);
  }
}
for (const [label, group] of [['initial', scripts.initial], ['deferred', scripts.deferred], ['unreferenced (not counted)', scripts.unreferenced]]) {
  for (const file of group.files) console.log(`  ${label}: ${file.url} ${file.raw} raw / ${file.gzip} gzip`);
}
if (failed) process.exitCode = 1;
