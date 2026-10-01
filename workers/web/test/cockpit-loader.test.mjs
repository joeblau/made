import assert from 'node:assert/strict';
import test from 'node:test';
import { startCockpit, staticReason } from '../src/scripts/cockpit-loader.js';

function environment(overrides = {}) {
  const calls = { load: 0, init: 0 };
  return {
    calls,
    navigator: {},
    hasWebGL: () => true,
    whenReady: async () => {},
    load: async () => {
      calls.load++;
      return { initCockpit: () => { calls.init++; return { state: 'running' }; } };
    },
    ...overrides,
  };
}

test('constrained devices keep the static fallback without fetching the scene', async () => {
  for (const [navigator, hasWebGL, reason] of [
    [{ connection: { saveData: true } }, () => true, 'save-data'],
    [{ connection: { effectiveType: '2g' } }, () => true, 'slow-connection'],
    [{ connection: { effectiveType: 'slow-2g' } }, () => true, 'slow-connection'],
    [{}, () => false, 'no-webgl'],
  ]) {
    const env = environment({ navigator, hasWebGL });
    const root = { dataset: {} };
    assert.equal(staticReason(env), reason === 'no-webgl' ? null : reason);
    assert.equal(await startCockpit(root, env), reason);
    assert.equal(root.dataset.cockpitState, 'static');
    assert.equal(env.calls.load, 0, 'the deferred chunk is never requested');
  }
});

test('the scene loads only after the page is ready and reveals on success', async () => {
  let release;
  let probes = 0;
  const ready = new Promise((resolve) => { release = resolve; });
  const env = environment({
    navigator: { connection: { effectiveType: '4g' } },
    whenReady: () => ready,
    hasWebGL: () => { probes++; return true; },
  });
  const root = { dataset: {} };
  const started = startCockpit(root, env);
  await Promise.resolve();
  assert.equal(root.dataset.cockpitState, 'pending');
  assert.equal(env.calls.load, 0, 'nothing is fetched before load + idle');
  assert.equal(probes, 0, 'no WebGL context is created before load + idle');
  release();
  assert.equal(await started, 'ready');
  assert.equal(root.dataset.cockpitState, 'ready');
  assert.deepEqual(env.calls, { load: 1, init: 1 });
});

test('a failed chunk or initializer leaves the static fallback in place', async () => {
  const errors = [];
  const failedLoad = environment({
    load: async () => { throw new Error('offline'); },
    reportError: (error) => errors.push(error),
  });
  const root = { dataset: {} };
  assert.equal(await startCockpit(root, failedLoad), 'failed');
  assert.equal(root.dataset.cockpitState, 'static');
  assert.equal(errors.length, 1);

  const noContext = environment({ load: async () => ({ initCockpit: () => null }) });
  const second = { dataset: {} };
  assert.equal(await startCockpit(second, noContext), 'no-webgl');
  assert.equal(second.dataset.cockpitState, 'static');
});
