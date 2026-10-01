/*
 * Scheduling and lifecycle for the decorative cockpit scene, kept free of
 * Three.js so it can be exercised with a fake window in tests.
 *
 * - Cadence: requestAnimationFrame callbacks arrive at the display's refresh
 *   rate (60-144 Hz); the scene advances and renders at most `maxFps` times a
 *   second regardless. Callbacks that arrive early are skipped cheaply.
 * - Motion: the prefers-reduced-motion query is watched live. Turning it on
 *   cancels the pending frame immediately and leaves a still frame; turning
 *   it off resumes exactly one loop.
 * - Static redraw: while not animating (reduced motion, hidden, or paused),
 *   a resize recomputes the viewport and redraws one still frame.
 * - Ownership: every listener the controller or scene registers uses
 *   `signal`, so dispose() removes them all, cancels the frame, and calls the
 *   scene's own dispose exactly once.
 */

const MAX_DT_SECONDS = 0.05;

/**
 * @param {object} options
 * @param {Window} options.win the window (or a test double) providing rAF, matchMedia, document
 * @param {number} options.maxFps upper bound on rendered frames per second
 * @param {(dt: number) => void} options.step advance the simulation by dt seconds
 * @param {() => void} options.draw render the current state
 * @param {() => void} options.resize recompute viewport-dependent sizes
 * @param {() => void} options.dispose release scene resources
 */
export function createSceneController({ win, maxFps, step, draw, resize, dispose }) {
  const interval = 1000 / maxFps;
  // Frames are due on a fixed schedule that advances by `interval` per render,
  // so the long-run rate never exceeds maxFps on any display. A callback this
  // close to its due time still renders, so vsync jitter cannot drop a frame.
  const tolerance = Math.min(2, interval / 4);
  const lifetime = new AbortController();
  const motionQuery = win.matchMedia('(prefers-reduced-motion: reduce)');

  let state = 'idle'; // idle | running | still | paused | disposed
  let pausedByUser = false;
  let rafHandle = 0;
  let lastRender = null; // rAF timestamp of the last rendered frame
  let nextDue = null; // schedule time of the next frame
  let stepped = false;

  const reduced = () => motionQuery.matches;
  const hidden = () => win.document.visibilityState === 'hidden';

  function cancel() {
    if (rafHandle) win.cancelAnimationFrame(rafHandle);
    rafHandle = 0;
  }

  function stillFrame() {
    // The first still frame advances by zero so instruments paint once.
    if (!stepped) {
      step(0);
      stepped = true;
    }
    draw();
  }

  function tick(now) {
    rafHandle = 0;
    if (state !== 'running') return;
    rafHandle = win.requestAnimationFrame(tick);
    if (nextDue !== null && now < nextDue - tolerance) return;
    // Fell more than a frame behind (a long task or a throttled tab): restart
    // the schedule from now instead of rendering a catch-up burst.
    nextDue = nextDue === null || now - nextDue > interval ? now + interval : nextDue + interval;
    const dt = lastRender === null ? 0 : Math.min((now - lastRender) / 1000, MAX_DT_SECONDS);
    lastRender = now;
    step(dt);
    stepped = true;
    draw();
  }

  /** Moves to whichever of running/still/paused the current conditions call for. */
  function settle() {
    if (state === 'disposed' || state === 'idle') return;
    const next = pausedByUser || hidden() ? 'paused' : reduced() ? 'still' : 'running';
    if (next === state) return;
    const previous = state;
    state = next;
    if (next === 'running') {
      lastRender = null; // resume without a time jump
      nextDue = null;
      rafHandle = win.requestAnimationFrame(tick);
    } else {
      cancel();
      if (next === 'still' || previous === 'idle') stillFrame();
    }
  }

  function onResize() {
    resize();
    // A running loop picks the new size up on its next frame.
    if (state === 'still' || state === 'paused') draw();
  }

  return {
    /** AbortSignal that scene listeners should register with. */
    signal: lifetime.signal,
    get state() {
      return state;
    },
    start() {
      if (state !== 'idle') return;
      const { signal } = lifetime;
      win.addEventListener('resize', onResize, { signal });
      motionQuery.addEventListener('change', settle, { signal });
      win.document.addEventListener('visibilitychange', settle, { signal });
      // Back/forward cache: pagehide may freeze the page with a loop pending.
      win.addEventListener('pagehide', () => { cancel(); if (state === 'running') state = 'paused'; }, { signal });
      win.addEventListener('pageshow', settle, { signal });
      resize();
      state = 'paused';
      if (!pausedByUser && !hidden()) {
        state = 'still';
        stillFrame();
      }
      settle();
    },
    pause() {
      pausedByUser = true;
      settle();
    },
    resume() {
      pausedByUser = false;
      settle();
    },
    dispose() {
      if (state === 'disposed') return;
      state = 'disposed';
      cancel();
      lifetime.abort();
      dispose();
    },
  };
}
