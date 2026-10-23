/*
 * Defers the decorative cockpit scene until the landing page is usable.
 * Three.js and the scene ship as a separate chunk fetched by dynamic import
 * after the load event and an idle period. Until it renders (and forever when
 * it is skipped or fails) the background is the themed page color plus the
 * vignette scrim, styled from data-cockpit-state on the container:
 *
 *   pending - waiting to load or initialize
 *   ready   - the scene initialized; canvases fade in
 *   static  - deliberate fallback: reduced motion, Save-Data, 2G, no WebGL,
 *             or a load failure
 */

const IDLE_TIMEOUT_MS = 2000;
const SLOW_CONNECTIONS = new Set(['slow-2g', '2g']);

/**
 * Returns why the scene should never be fetched on this visit, or null.
 * Cheap enough to run at module evaluation; the WebGL probe is not, so it
 * waits until after load (see startCockpit).
 */
export function staticReason(env) {
  if (env.reducedMotion?.()) return 'reduced-motion';
  const connection = env.navigator?.connection;
  if (connection?.saveData === true) return 'save-data';
  if (SLOW_CONNECTIONS.has(connection?.effectiveType)) return 'slow-connection';
  return null;
}

/** Probes for WebGL2 on a throwaway canvas and releases the context. */
export function probeWebGL(doc = document) {
  try {
    const canvas = doc.createElement('canvas');
    const gl = canvas.getContext('webgl2');
    if (!gl) return false;
    gl.getExtension('WEBGL_lose_context')?.loseContext();
    return true;
  } catch {
    return false;
  }
}

/** Resolves after the load event and then an idle slice (or a short timeout). */
export function afterLoadAndIdle(win = window) {
  return new Promise((resolve) => {
    const idle = () => {
      // requestIdleCallback is unavailable on Safari < 18.
      if (typeof win.requestIdleCallback === 'function') {
        win.requestIdleCallback(() => resolve(), { timeout: IDLE_TIMEOUT_MS });
      } else {
        win.setTimeout(resolve, 200);
      }
    };
    if (win.document.readyState === 'complete') idle();
    else win.addEventListener('load', idle, { once: true });
  });
}

/**
 * Loads and starts the scene unless this visit gets the static fallback.
 * `load` returns the scene module; its `initCockpit(root)` returns a truthy
 * value once the scene is running, or null when its canvases are missing or
 * WebGL turned out to be unavailable.
 */
export async function startCockpit(root, env) {
  const reason = staticReason(env);
  if (reason) {
    root.dataset.cockpitState = 'static';
    return reason;
  }
  root.dataset.cockpitState = 'pending';
  try {
    await env.whenReady();
    // Probing creates (and releases) a GL context, which can start the GPU
    // process; keep that off the critical path before the load event.
    if (!env.hasWebGL()) {
      root.dataset.cockpitState = 'static';
      return 'no-webgl';
    }
    const { initCockpit } = await env.load();
    const started = initCockpit(root);
    root.dataset.cockpitState = started ? 'ready' : 'static';
    return started ? 'ready' : 'no-webgl';
  } catch (error) {
    root.dataset.cockpitState = 'static';
    env.reportError?.(error);
    return 'failed';
  }
}

export function loadCockpitWhenIdle() {
  const root = document.querySelector('.cockpit-bg');
  if (!(root instanceof HTMLElement)) return Promise.resolve('missing');
  return startCockpit(root, {
    navigator,
    reducedMotion: () => matchMedia('(prefers-reduced-motion: reduce)').matches,
    hasWebGL: () => probeWebGL(document),
    whenReady: () => afterLoadAndIdle(window),
    load: () => import('./f35-cockpit.js'),
    // Decorative only: surface the failure for debugging, never to the user.
    reportError: (error) => console.warn('Cockpit background unavailable', error),
  });
}
