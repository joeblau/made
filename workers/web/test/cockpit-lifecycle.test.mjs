import assert from 'node:assert/strict';
import test from 'node:test';
import {
  COCKPIT_FRAME_INTERVAL_MS,
  createCockpitController,
  disposeCockpitResources,
} from '../src/scripts/cockpit-lifecycle.js';

function frameQueue() {
  let nextId = 1;
  const callbacks = new Map();
  return {
    callbacks,
    request(callback) {
      const id = nextId++;
      callbacks.set(id, callback);
      return id;
    },
    cancel(id) { callbacks.delete(id); },
    step(timestamp) {
      const pending = [...callbacks.values()];
      callbacks.clear();
      for (const callback of pending) callback(timestamp);
    },
  };
}

function controlledController(render = () => {}) {
  const queue = frameQueue();
  const controller = createCockpitController({
    render,
    requestFrame: queue.request,
    cancelFrame: queue.cancel,
  });
  return { controller, queue };
}

test('render cadence stays at 30 Hz on a 120 Hz scheduler', () => {
  const renders = [];
  const { controller, queue } = controlledController((dt) => renders.push(dt));
  controller.start();
  for (let frame = 0; frame <= 120; frame++) queue.step(frame * 1000 / 120);

  assert.equal(COCKPIT_FRAME_INTERVAL_MS, 1000 / 30);
  assert.equal(renders.length, 30);
  assert.ok(renders.every((dt) => dt > 0 && dt <= 0.05));
  controller.dispose();
});

test('pause, resume, and dispose never leave duplicate or stale frame callbacks', () => {
  let renders = 0;
  const { controller, queue } = controlledController(() => { renders++; });
  controller.start();
  controller.start();
  assert.equal(queue.callbacks.size, 1);
  queue.step(0);
  const [staleFrame] = queue.callbacks.values();

  controller.pause();
  assert.equal(queue.callbacks.size, 0);
  staleFrame(50);
  assert.equal(renders, 0);
  assert.equal(queue.callbacks.size, 0);

  controller.resume();
  controller.resume();
  assert.equal(queue.callbacks.size, 1);
  queue.step(100);
  queue.step(100 + COCKPIT_FRAME_INTERVAL_MS);
  assert.equal(renders, 1);

  controller.dispose();
  controller.dispose();
  assert.equal(controller.disposed, true);
  assert.equal(queue.callbacks.size, 0);
  controller.resume();
  assert.equal(queue.callbacks.size, 0);
});

test('resource disposal releases shared GPU resources exactly once', () => {
  const disposed = [];
  const resource = (name) => ({ dispose: () => disposed.push(name) });
  const geometry = resource('geometry');
  const map = { isTexture: true, ...resource('map') };
  const emissiveMap = { isTexture: true, ...resource('emissive') };
  const uniformMap = { isTexture: true, ...resource('uniform') };
  const material = {
    map,
    emissiveMap,
    uniforms: { texture: { value: uniformMap } },
    ...resource('material'),
  };
  const shadowMap = resource('shadow');
  const environmentTarget = resource('environment');
  const scene = {
    environment: {},
    traverse(callback) {
      callback({ geometry, material });
      callback({ geometry, material });
      callback({ shadow: { map: shadowMap } });
    },
    clear() { disposed.push('clear'); },
  };
  const renderer = resource('renderer');

  disposeCockpitResources(scene, environmentTarget, renderer);

  assert.deepEqual(disposed.sort(), [
    'clear', 'emissive', 'environment', 'geometry', 'map', 'material',
    'renderer', 'shadow', 'uniform',
  ].sort());
  assert.equal(scene.environment, null);
});
