import assert from 'node:assert/strict';
import test from 'node:test';
import { nextTheme, normalizeTheme } from '../src/scripts/theme.js';

test('theme values are limited to light and dark', () => {
  assert.equal(normalizeTheme('light'), 'light');
  assert.equal(normalizeTheme('dark'), 'dark');
  for (const value of ['system', '', null, undefined, 0]) assert.equal(normalizeTheme(value), null);
});

test('theme changes always select the opposite appearance', () => {
  assert.equal(nextTheme('light'), 'dark');
  assert.equal(nextTheme('dark'), 'light');
  assert.equal(nextTheme('system'), 'dark');
});
