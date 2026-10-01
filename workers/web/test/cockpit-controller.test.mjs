import assert from 'node:assert/strict';
import test from 'node:test';
import { createSceneController } from '../src/scripts/cockpit-controller.js';

/** A window double with a manual frame clock and observable listeners. */
function fakeWindow({ reduced = false } = {}) {
  const win = new EventTarget();
  const document = new EventTarget();
  document.visibilityState = 'visible';
  const motion = new EventTarget();
  motion.matches = reduced;
  let nextHandle = 1;
  const frames = new Map();
  const listenerCounts = new Map();
  for (const target of [win, document, motion]) {
    const add = target.addEventListener.bind(target);
    target.addEventListener = (type, fn, options) => {
      listenerCounts.set(type, (listenerCounts.get(type) ?? 0) + 1);
      options?.signal?.addEventListener('abort', () => listenerCounts.set(type, listenerCounts.get(type) - 1));
      add(type, fn, options);
    };
  }
  Object.assign(win, {
    document,
    matchMedia: () => motion,
    requestAnimationFrame(fn) {
      const handle = nextHandle++;
      frames.set(handle, fn);
      return handle;
    },
    cancelAnimationFrame(handle) {
      frames.delete(handle);
    },
  });
  return {
    win,
    pendingFrames: () => frames.size,
    liveListeners: () => [...listenerCounts.values()].reduce((sum, n) => sum + n, 0),
    /** Deliver vsync callbacks at `hz` for `ms` milliseconds starting at `from`. */
    vsync(hz, ms, from = 0) {
      const period = 1000 / hz;
      let now = from;
      for (let i = 1; now < from + ms; i++) {
        now = from + i * period;
        const callbacks = [...frames.values()];
        frames.clear();
        for (const fn of callbacks) fn(now);
      }
      return now;
    },
    setReduced(value) {
      motion.matches = value;
      motion.dispatchEvent(new Event('change'));
    },
    setHidden(value) {
      document.visibilityState = value ? 'hidden' : 'visible';
      document.dispatchEvent(new Event('visibilitychange'));
    },
  };
}

function scene(fake, maxFps = 30) {
  const counts = { step: 0, draw: 0, resize: 0, dispose: 0, dts: [] };
  const controller = createSceneController({
    win: fake.win,
    maxFps,
    step: (dt) => { counts.step++; counts.dts.push(dt); },
    draw: () => { counts.draw++; },
    resize: () => { counts.resize++; },
    dispose: () => { counts.dispose++; },
  });
  return { controller, counts };
}

test('render cadence is capped independent of display refresh rate', () => {
  for (const hz of [60, 90, 120, 144, 240]) {
    const fake = fakeWindow();
    const { controller, counts } = scene(fake, 30);
    controller.start();
    const initial = counts.draw;
    fake.vsync(hz, 10_000);
    const fps = (counts.draw - initial) / 10;
    assert.ok(fps <= 30.1 && fps >= 28, `${hz} Hz display renders ${fps} FPS`);
    assert.ok(counts.dts.every((dt) => dt <= 0.05), 'dt stays clamped');
    controller.dispose();
  }
});

test('a 60 FPS cap renders every frame at 60 Hz and never more at 144 Hz', () => {
  const at60 = fakeWindow();
  const a = scene(at60, 60);
  a.controller.start();
  const start = a.counts.draw;
  at60.vsync(60, 1000);
  assert.ok(a.counts.draw - start >= 59, `${a.counts.draw - start} frames at 60 Hz`);

  const at144 = fakeWindow();
  const b = scene(at144, 60);
  b.controller.start();
  const before = b.counts.draw;
  at144.vsync(144, 1000);
  assert.ok(b.counts.draw - before <= 61, `${b.counts.draw - before} frames at 144 Hz`);
});

test('reduced motion stops immediately and resumes exactly one loop', () => {
  const fake = fakeWindow();
  const { controller, counts } = scene(fake);
  controller.start();
  assert.equal(controller.state, 'running');
  let now = fake.vsync(60, 500);

  fake.setReduced(true);
  assert.equal(controller.state, 'still');
  assert.equal(fake.pendingFrames(), 0, 'the pending frame is cancelled at once');
  const steps = counts.step;
  now = fake.vsync(60, 1000, now);
  assert.equal(counts.step, steps, 'no simulation while reduced');

  fake.setReduced(false);
  fake.setReduced(false); // duplicate notifications must not start a second loop
  assert.equal(fake.pendingFrames(), 1);
  const resumed = counts.draw;
  fake.vsync(60, 1000, now);
  assert.ok(counts.draw - resumed <= 31, 'one loop at the capped cadence');
  assert.equal(counts.dts[steps], 0, 'resuming does not jump the clock');
});

test('static mode redraws on resize without starting animation', () => {
  const fake = fakeWindow({ reduced: true });
  const { controller, counts } = scene(fake);
  controller.start();
  assert.equal(controller.state, 'still');
  assert.deepEqual([counts.step, counts.draw, counts.resize], [1, 1, 1], 'one still frame at start');
  assert.equal(counts.dts[0], 0);

  fake.win.dispatchEvent(new Event('resize'));
  assert.deepEqual([counts.step, counts.draw, counts.resize], [1, 2, 2], 'redrawn, not advanced');
  assert.equal(fake.pendingFrames(), 0, 'no loop was started');

  const running = fakeWindow();
  const live = scene(running);
  live.controller.start();
  const draws = live.counts.draw;
  running.win.dispatchEvent(new Event('resize'));
  assert.equal(live.counts.draw, draws, 'an animating scene picks the size up on its next frame');
});

test('hidden pages, pagehide, and explicit pause stop the loop until resumed', () => {
  const fake = fakeWindow();
  const { controller, counts } = scene(fake);
  controller.start();
  fake.setHidden(true);
  assert.equal(controller.state, 'paused');
  assert.equal(fake.pendingFrames(), 0);
  fake.setHidden(false);
  assert.equal(controller.state, 'running');
  assert.equal(fake.pendingFrames(), 1);

  fake.win.dispatchEvent(new Event('pagehide'));
  assert.equal(fake.pendingFrames(), 0);
  fake.win.dispatchEvent(new Event('pageshow'));
  assert.equal(fake.pendingFrames(), 1);

  controller.pause();
  fake.setHidden(false);
  assert.equal(controller.state, 'paused', 'visibility does not override an explicit pause');
  const draws = counts.draw;
  fake.win.dispatchEvent(new Event('resize'));
  assert.equal(counts.draw, draws + 1, 'paused scenes redraw statically on resize');
  controller.resume();
  controller.resume();
  assert.equal(fake.pendingFrames(), 1);
});

test('repeated start and dispose leave no frames or listeners behind', () => {
  const fake = fakeWindow();
  for (let i = 0; i < 5; i++) {
    const { controller, counts } = scene(fake);
    controller.start();
    controller.start();
    assert.equal(fake.pendingFrames(), 1, 'start is idempotent');
    controller.dispose();
    controller.dispose();
    assert.equal(counts.dispose, 1, 'scene resources are released exactly once');
    assert.equal(controller.state, 'disposed');
    assert.equal(fake.pendingFrames(), 0);
    assert.equal(fake.liveListeners(), 0);
    controller.resume();
    fake.setReduced(false);
    fake.win.dispatchEvent(new Event('resize'));
    assert.equal(fake.pendingFrames(), 0, 'a disposed controller stays inert');
  }
});
