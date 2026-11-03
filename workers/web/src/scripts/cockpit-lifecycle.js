export const COCKPIT_FRAME_INTERVAL_MS = 1000 / 30;

const MAX_FRAME_DELTA_MS = 50;
const FRAME_EPSILON_MS = 0.01;

export function createCockpitController({
  render,
  requestFrame = requestAnimationFrame,
  cancelFrame = cancelAnimationFrame,
  frameInterval = COCKPIT_FRAME_INTERVAL_MS,
}) {
  let frameId = null;
  let previousTime = null;
  let accumulated = 0;
  let running = false;
  let disposed = false;

  function schedule() {
    if (running && !disposed && frameId === null) frameId = requestFrame(tick);
  }

  function tick(timestamp) {
    frameId = null;
    if (!running || disposed) return;
    if (previousTime === null) previousTime = timestamp;
    accumulated += Math.min(Math.max(timestamp - previousTime, 0), MAX_FRAME_DELTA_MS);
    previousTime = timestamp;
    if (accumulated + FRAME_EPSILON_MS >= frameInterval) {
      const dt = Math.min(accumulated, MAX_FRAME_DELTA_MS) / 1000;
      accumulated = 0;
      render(dt);
    }
    schedule();
  }

  function resume() {
    if (disposed || running) return;
    running = true;
    previousTime = null;
    accumulated = 0;
    schedule();
  }

  function pause() {
    if (disposed) return;
    running = false;
    previousTime = null;
    accumulated = 0;
    if (frameId !== null) cancelFrame(frameId);
    frameId = null;
  }

  function dispose() {
    if (disposed) return;
    pause();
    disposed = true;
  }

  return {
    start: resume,
    pause,
    resume,
    dispose,
    get running() { return running; },
    get disposed() { return disposed; },
  };
}

export function disposeCockpitResources(scene, environmentTarget, renderer) {
  const geometries = new Set();
  const materials = new Set();
  const textures = new Set();
  const renderTargets = new Set();

  scene.traverse((object) => {
    if (object.geometry) geometries.add(object.geometry);
    if (object.shadow?.map) renderTargets.add(object.shadow.map);
    const objectMaterials = Array.isArray(object.material) ? object.material : [object.material];
    for (const material of objectMaterials) {
      if (!material) continue;
      materials.add(material);
      for (const value of Object.values(material)) {
        if (value?.isTexture) textures.add(value);
      }
      for (const uniform of Object.values(material.uniforms ?? {})) {
        if (uniform.value?.isTexture) textures.add(uniform.value);
      }
    }
  });

  for (const texture of textures) texture.dispose();
  for (const material of materials) material.dispose();
  for (const geometry of geometries) geometry.dispose();
  for (const target of renderTargets) target.dispose();
  environmentTarget.dispose();
  scene.environment = null;
  scene.clear();
  renderer.dispose();
}
