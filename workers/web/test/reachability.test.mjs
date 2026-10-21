import { readdir, readFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import test from 'node:test';

const src = fileURLToPath(new URL('../src/', import.meta.url));
const sourceExtensions = ['.astro', '.ts', '.js', '.mjs', '.css'];

async function filesUnder(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else files.push(path);
  }
  return files;
}

// Static `import ... from './x'`, side-effect `import './x'`, dynamic
// `import('./x')`, and CSS `@import './x'` specifiers. Package imports are
// ignored; only relative edges inside src/ matter for reachability.
function relativeImports(text) {
  const specifiers = [];
  const patterns = [
    /\bimport\s+(?:[^'"]*?\sfrom\s+)?['"](\.{1,2}\/[^'"]+)['"]/g,
    /\bimport\s*\(\s*['"](\.{1,2}\/[^'"]+)['"]\s*\)/g,
    /@import\s+['"](\.{1,2}\/[^'"]+)['"]/g,
  ];
  for (const pattern of patterns) {
    for (const [, specifier] of text.matchAll(pattern)) specifiers.push(specifier);
  }
  return specifiers;
}

// Mirrors Vite's resolution of the specifiers this site uses: an exact file,
// an extensionless module ('./foo' -> foo.ts), or a directory index.
function resolveSource(all, from, specifier) {
  const base = resolve(dirname(from), specifier);
  const candidates = [
    base,
    ...sourceExtensions.map((ext) => base + ext),
    ...sourceExtensions.map((ext) => join(base, `index${ext}`)),
  ];
  return candidates.find((candidate) => all.includes(candidate));
}

test('every web source file is reachable from a page entrypoint', async () => {
  const all = (await filesUnder(src)).filter((path) => sourceExtensions.some((ext) => path.endsWith(ext)));
  const pages = all.filter((path) => relative(src, path).startsWith('pages/'));
  assert.ok(pages.length >= 2, 'both the / and /made routes exist');

  const reached = new Set();
  const queue = [...pages];
  while (queue.length > 0) {
    const file = queue.pop();
    if (reached.has(file)) continue;
    reached.add(file);
    for (const specifier of relativeImports(await readFile(file, 'utf8'))) {
      const target = resolveSource(all, file, specifier);
      assert.ok(target, `${relative(src, file)} imports ${specifier}, which resolves to no source file`);
      queue.push(target);
    }
  }

  const unreachable = all.filter((path) => !reached.has(path)).map((path) => relative(src, path));
  assert.deepEqual(unreachable, [], 'delete unreachable components/scripts instead of leaving them to drift');
});
