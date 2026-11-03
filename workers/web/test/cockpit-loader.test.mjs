import assert from 'node:assert/strict';
import test from 'node:test';
import { afterLoadAndIdle, startCockpit, staticReason } from '../src/scripts/cockpit-loader.js';

function environment(overrides = {}) {
  const calls = { load: 0, init: 0 };
  return {
    calls,
    navigator: {},
    reducedMotion: () => false,
    hasWebGL: () => true,
    whenReady: async () => {},
    load: async () => {
      calls.load++;
      return { initCockpit: () => { calls.init++; return true; } };
    },
    ...overrides,
  };
}

test('constrained devices keep the static fallback without fetching the scene', async () => {
  for (const [overrides, reason] of [
    [{ navigator: { connection: { saveData: true } } }, 'save-data'],
    [{ navigator: { connection: { effectiveType: '2g' } } }, 'slow-connection'],
    [{ navigator: { connection: { effectiveType: 'slow-2g' } } }, 'slow-connection'],
    [{ hasWebGL: () => false }, 'no-webgl'],
  ]) {
    const env = environment(overrides);
    const root = { dataset: {} };
    assert.equal(staticReason(env), reason === 'no-webgl' ? null : reason);
    assert.equal(await startCockpit(root, env), reason);
    assert.equal(root.dataset.cockpitState, 'static');
    assert.equal(env.calls.load, 0, 'the deferred chunk is never requested');
  }
});

test('reduced motion initializes a static scene that can resume later', async () => {
  const env = environment({ reducedMotion: () => true });
  const root = { dataset: {} };
  assert.equal(staticReason(env), null);
  assert.equal(await startCockpit(root, env), 'ready');
  assert.equal(root.dataset.cockpitState, 'ready');
  assert.deepEqual(env.calls, { load: 1, init: 1 });
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

  const failedInit = environment({
    load: async () => ({ initCockpit: () => { throw new Error('GPU initialization failed'); } }),
    reportError: (error) => errors.push(error),
  });
  const third = { dataset: {} };
  assert.equal(await startCockpit(third, failedInit), 'failed');
  assert.equal(third.dataset.cockpitState, 'static');
  assert.equal(errors.length, 2);
});

test('idle scheduling waits for window load before requesting an idle slice', async () => {
  let onLoad;
  let onIdle;
  const win = {
    document: { readyState: 'loading' },
    addEventListener: (type, listener, options) => {
      assert.equal(type, 'load');
      assert.deepEqual(options, { once: true });
      onLoad = listener;
    },
    requestIdleCallback: (listener, options) => {
      assert.deepEqual(options, { timeout: 2000 });
      onIdle = listener;
    },
  };
  const scheduled = afterLoadAndIdle(win);
  assert.equal(onIdle, undefined, 'no idle callback is requested before load');
  onLoad();
  assert.equal(typeof onIdle, 'function');
  onIdle();
  await scheduled;
});

test('idle scheduling has a timer fallback after an earlier load event', async () => {
  let onTimeout;
  const win = {
    document: { readyState: 'complete' },
    setTimeout: (listener, delay) => {
      assert.equal(delay, 200);
      onTimeout = listener;
    },
  };
  const scheduled = afterLoadAndIdle(win);
  assert.equal(typeof onTimeout, 'function');
  onTimeout();
  await scheduled;
});

test('the graphics probe requires WebGL2 and releases a successful context', async () => {
  const { probeWebGL } = await import('../src/scripts/cockpit-loader.js');
  const requests = [];
  const unavailable = {
    createElement: () => ({
      getContext: (type) => { requests.push(type); return null; },
    }),
  };
  assert.equal(probeWebGL(unavailable), false);
  assert.deepEqual(requests, ['webgl2'], 'WebGL1 is never requested');

  let released = 0;
  const available = {
    createElement: () => ({
      getContext: (type) => type === 'webgl2' ? {
        getExtension: () => ({ loseContext: () => { released++; } }),
      } : null,
    }),
  };
  assert.equal(probeWebGL(available), true);
  assert.equal(released, 1);
});
