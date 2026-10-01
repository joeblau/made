/*
 * Defers the decorative cockpit scene until the download slate is usable.
 * The page's critical script graph is only this loader and the QR dialog;
 * Three.js and the scene ship as a separate chunk fetched by dynamic import
 * after the load event and an idle period. Until it renders (and forever when
 * it is skipped or fails) the background is the themed page color plus the
 * vignette scrim, styled from data-cockpit-state on the container:
 *
 *   pending - waiting to load or initialize
 *   ready   - the scene rendered its first frame; canvases fade in
 *   static  - deliberate fallback: no WebGL, Save-Data/2G, or a load failure
 *
 * Reduced motion still loads the scene: it renders a still frame rather than
 * an animation, matching the behavior before the scene was deferred.
 */

const IDLE_TIMEOUT_MS = 2000;
const SLOW_CONNECTIONS = new Set(['slow-2g', '2g']);

/**
 * Returns why the scene should stay static on this connection, or null.
 * Cheap enough to run at module evaluation; the WebGL probe is not, so it
 * waits until after load (see startCockpit).
 */
export function staticReason(env) {
  const connection = env.navigator?.connection;
  if (connection?.saveData === true) return 'save-data';
  if (SLOW_CONNECTIONS.has(connection?.effectiveType)) return 'slow-connection';
  return null;
}

/** Probes for WebGL on a throwaway canvas and releases the context. */
export function probeWebGL(doc = document) {
  try {
    const canvas = doc.createElement('canvas');
    const gl = canvas.getContext('webgl2') ?? canvas.getContext('webgl');
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
 * Loads and starts the scene unless the device gets the static fallback.
 * `load` returns the scene module; its `initCockpit(root)` returns the scene
 * controller once the first frame is drawn, or null when WebGL turned out to
 * be unavailable.
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
    const handle = await initCockpit(root);
    root.dataset.cockpitState = handle ? 'ready' : 'static';
    return handle ? 'ready' : 'no-webgl';
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
    hasWebGL: () => probeWebGL(document),
    whenReady: () => afterLoadAndIdle(window),
    load: () => import('./f35-cockpit.js'),
    // Decorative only: surface the failure for debugging, never to the user.
    reportError: (error) => console.warn('Cockpit background unavailable', error),
  });
}
