import assert from 'node:assert/strict';
import test from 'node:test';
import { clampIndex } from '../src/scripts/interactions.js';

test('workflow indexes stay within the available chapters', () => {
  assert.equal(clampIndex(0, 4), 0);
  assert.equal(clampIndex(3, 4), 3);
  assert.equal(clampIndex(8, 4), 3);
  assert.equal(clampIndex(-2, 4), 0);
  assert.equal(clampIndex(0, 0), 0);
});
