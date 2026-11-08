import assert from 'node:assert/strict';
import test from 'node:test';
import { initCockpit } from '../src/scripts/f35-cockpit.js';

class TrackedEventTarget extends EventTarget {
  constructor() {
    super();
    this.listeners = new Map();
  }

  addEventListener(type, listener, options) {
    super.addEventListener(type, listener, options);
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(listener);
  }

  removeEventListener(type, listener, options) {
    super.removeEventListener(type, listener, options);
    this.listeners.get(type)?.delete(listener);
  }

  get listenerCount() {
    return [...this.listeners.values()].reduce((count, listeners) => count + listeners.size, 0);
  }
}

class FakeCanvas extends TrackedEventTarget {
  constructor() {
    super();
    this.width = 0;
    this.height = 0;
    this.attributes = {};
    const gradient = { addColorStop() {} };
    this.context = new Proxy({
      createImageData: (width, height) => ({ data: new Uint8ClampedArray(width * height * 4) }),
      createLinearGradient: () => gradient,
      createRadialGradient: () => gradient,
    }, {
      get: (target, property) => target[property] ?? (() => {}),
    });
  }

  getContext(type) {
    assert.equal(type, '2d');
    return this.context;
  }

  cloneNode(deep) {
    assert.equal(deep, false);
    const clone = new FakeCanvas();
    clone.width = this.width;
    clone.height = this.height;
    clone.attributes = { ...this.attributes };
    return clone;
  }

  replaceWith(replacement) {
    this.replacement = replacement;
    this.parent.replaceCanvas(this, replacement);
  }
}

class FakeRoot extends TrackedEventTarget {
  constructor() {
    super();
    this.sceneCanvas = new FakeCanvas();
    this.sceneCanvas.attributes = {
      'aria-hidden': 'true',
      class: 'cockpit-scene',
      'data-cockpit-scene': '',
    };
    this.sceneCanvas.parent = this;
    this.hudCanvas = new FakeCanvas();
    this.hudCanvas.parent = this;
  }

  querySelector(selector) {
    if (selector === '[data-cockpit-scene]') return this.sceneCanvas;
    if (selector === '[data-cockpit-hud]') return this.hudCanvas;
    return null;
  }

  closest() {
    return this;
  }

  replaceCanvas(current, replacement) {
    assert.equal(current, this.sceneCanvas);
    this.sceneCanvas = replacement;
    replacement.parent = this;
  }

  getBoundingClientRect() {
    return { left: 0, top: 0, width: 1280, height: 720 };
  }
}

function trackSceneResources(scene) {
  const geometries = new Set();
  const materials = new Set();
  const textures = new Set();
  const disposedGeometries = new Set();
  const disposedMaterials = new Set();
  const disposedTextures = new Set();
  scene.traverse((object) => {
    if (object.geometry) geometries.add(object.geometry);
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
  for (const geometry of geometries) geometry.addEventListener('dispose', () => disposedGeometries.add(geometry));
  for (const material of materials) material.addEventListener('dispose', () => disposedMaterials.add(material));
  for (const texture of textures) texture.addEventListener('dispose', () => disposedTextures.add(texture));
  return {
    geometries, materials, textures,
    disposedGeometries, disposedMaterials, disposedTextures,
  };
}

function browserEnvironment(t) {
  const names = [
    'HTMLCanvasElement', 'IntersectionObserver', 'devicePixelRatio', 'document',
    'innerHeight', 'innerWidth', 'matchMedia', 'cancelAnimationFrame',
    'requestAnimationFrame', 'window',
  ];
  const originals = new Map(names.map((name) => [name, globalThis[name]]));
  t.after(() => {
    for (const [name, value] of originals) {
      if (value === undefined) delete globalThis[name];
      else globalThis[name] = value;
    }
  });

  const root = new FakeRoot();
  const document = new TrackedEventTarget();
  document.visibilityState = 'visible';
  document.createElement = (name) => {
    assert.equal(name, 'canvas');
    return new FakeCanvas();
  };
  const window = new TrackedEventTarget();
  window.devicePixelRatio = 1;
  const motionPreference = new TrackedEventTarget();
  motionPreference.matches = true;
  const mediaQueries = [motionPreference];
  const observers = [];
  const frames = new Map();
  let nextFrame = 1;

  globalThis.HTMLCanvasElement = FakeCanvas;
  globalThis.document = document;
  globalThis.window = window;
  globalThis.innerWidth = 1280;
  globalThis.innerHeight = 720;
  globalThis.devicePixelRatio = 1;
  globalThis.matchMedia = (query) => {
    if (query === '(prefers-reduced-motion: reduce)') return motionPreference;
    const mediaQuery = new TrackedEventTarget();
    mediaQuery.matches = false;
    mediaQueries.push(mediaQuery);
    return mediaQuery;
  };
  globalThis.IntersectionObserver = class {
    constructor(callback) {
      this.callback = callback;
      this.disconnected = false;
      observers.push(this);
    }

    observe(target) {
      this.target = target;
    }

    disconnect() {
      this.disconnected = true;
      this.target = null;
    }
  };
  globalThis.requestAnimationFrame = (callback) => {
    const id = nextFrame++;
    frames.set(id, callback);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => frames.delete(id);

  return {
    root, motionPreference, observers, frames,
    step(timestamp) {
      const pending = [...frames.values()];
      frames.clear();
      for (const callback of pending) callback(timestamp);
    },
    assertListenersRemoved() {
      for (const target of [root, document, window, ...mediaQueries]) {
        assert.equal(target.listenerCount, 0);
      }
    },
  };
}

function sceneDependencies(state) {
  class Renderer {
    constructor({ canvas }) {
      this.canvas = canvas;
      this.capabilities = { getMaxAnisotropy: () => 4 };
      this.shadowMap = {};
      this.disposals = 0;
      this.contextLosses = 0;
      this.renderCalls = 0;
      this.events = [];
      state.renderers.push(this);
    }

    setPixelRatio() {}
    setSize() {}
    setRenderTarget(target) { this.renderTarget = target; }

    render(scene) {
      this.renderCalls++;
      this.scene = scene;
      if (state.renderFailures > 0) {
        state.renderFailures--;
        this.resources = trackSceneResources(scene);
        throw new Error('induced initial render failure');
      }
    }

    dispose() {
      this.disposals++;
      this.events.push('dispose');
    }

    forceContextLoss() {
      this.contextLosses++;
      this.contextLostTarget = this.renderTarget;
      if (this.renderTarget) this.renderTarget.contextLosses++;
      this.events.push('context-loss');
    }
  }

  class EnvironmentGenerator {
    constructor(renderer) {
      this.renderer = renderer;
      this.disposals = 0;
      state.environmentGenerators.push(this);
    }

    fromScene(environmentScene) {
      const target = {
        texture: { isTexture: true },
        disposals: 0,
        contextLosses: 0,
        dispose() { this.disposals++; },
      };
      if (state.environmentFailures > 0) {
        state.environmentFailures--;
        state.partialEnvironmentTargets.push(target);
        this.renderer.setRenderTarget(target);
        const dome = environmentScene.children[0];
        this.geometryDisposed = false;
        this.materialDisposed = false;
        dome.geometry.addEventListener('dispose', () => { this.geometryDisposed = true; });
        dome.material.addEventListener('dispose', () => { this.materialDisposed = true; });
        throw new Error('induced environment generation failure');
      }
      state.environmentTargets.push(target);
      return target;
    }

    dispose() {
      this.disposals++;
    }
  }

  return { Renderer, EnvironmentGenerator };
}

function assertFailedSceneRolledBack(browser, state, attempt) {
  const renderer = state.renderers[attempt - 1];
  assert.equal(renderer.disposals, 1);
  assert.equal(renderer.contextLosses, 1);
  assert.deepEqual(renderer.events, ['dispose', 'context-loss']);
  assert.equal(renderer.scene.children.length, 0);
  assert.equal(renderer.scene.environment, null);
  assert.ok(renderer.resources.geometries.size > 50);
  assert.ok(renderer.resources.materials.size > 20);
  assert.ok(renderer.resources.textures.size > 10);
  assert.equal(renderer.resources.disposedGeometries.size, renderer.resources.geometries.size);
  assert.equal(renderer.resources.disposedMaterials.size, renderer.resources.materials.size);
  assert.equal(renderer.resources.disposedTextures.size, renderer.resources.textures.size);
  assert.equal(state.environmentGenerators[attempt - 1].disposals, 1);
  assert.equal(state.environmentTargets[attempt - 1].disposals, 1);
  assert.equal(browser.observers[attempt - 1].disconnected, true);
  browser.assertListenersRemoved();
  assert.equal(browser.frames.size, 0);
}

test('mid-initialization render failures roll back the real scene and permit repeated retries', (t) => {
  const browser = browserEnvironment(t);
  const state = {
    renderFailures: 2,
    renderers: [],
    environmentGenerators: [],
    environmentTargets: [],
  };
  const dependencies = sceneDependencies(state);

  for (let attempt = 1; attempt <= 2; attempt++) {
    assert.throws(
      () => initCockpit(browser.root, dependencies),
      /induced initial render failure/,
    );
    assertFailedSceneRolledBack(browser, state, attempt);
  }

  const cockpit = initCockpit(browser.root, dependencies);
  assert.ok(cockpit);
  assert.equal(initCockpit(browser.root, dependencies), cockpit);
  assert.equal(state.renderers.length, 3);
  assert.equal(state.renderers[2].contextLosses, 0);
  assert.equal(cockpit.running, false);
  assert.equal(browser.frames.size, 0);

  browser.motionPreference.matches = false;
  const motionChange = new Event('change');
  Object.defineProperty(motionChange, 'matches', { value: false });
  browser.motionPreference.dispatchEvent(motionChange);
  assert.equal(cockpit.running, true);
  assert.equal(browser.frames.size, 1);
  browser.step(0);
  browser.step(34);
  assert.equal(state.renderers[2].renderCalls, 2);
  assert.equal(browser.frames.size, 1);

  cockpit.dispose();
  cockpit.dispose();
  assert.equal(cockpit.disposed, true);
  assert.equal(cockpit.running, false);
  assert.equal(browser.frames.size, 0);
  assert.equal(state.renderers[2].disposals, 1);
  assert.equal(state.renderers[2].contextLosses, 0);
  assert.deepEqual(state.renderers[2].events, ['dispose']);
  assert.equal(state.environmentTargets[2].disposals, 1);
  assert.equal(browser.observers[2].disconnected, true);
  browser.assertListenersRemoved();
});

test('environment failure after output allocation uses a fresh canvas on retry', (t) => {
  const browser = browserEnvironment(t);
  const root = browser.root;
  const failedCanvas = root.sceneCanvas;
  const hudCanvas = root.hudCanvas;
  const canvasAttributes = { ...failedCanvas.attributes };
  const state = {
    environmentFailures: 1,
    renderers: [],
    environmentGenerators: [],
    environmentTargets: [],
    partialEnvironmentTargets: [],
  };
  const dependencies = sceneDependencies(state);

  assert.throws(
    () => initCockpit(root, dependencies),
    /induced environment generation failure/,
  );
  const renderer = state.renderers[0];
  const partialTarget = state.partialEnvironmentTargets[0];
  const retryCanvas = root.sceneCanvas;
  assert.equal(renderer.canvas, failedCanvas);
  assert.equal(renderer.disposals, 1);
  assert.equal(renderer.contextLosses, 1);
  assert.equal(renderer.contextLostTarget, partialTarget);
  assert.deepEqual(renderer.events, ['dispose', 'context-loss']);
  assert.equal(partialTarget.contextLosses, 1);
  assert.equal(partialTarget.disposals, 0);
  assert.notEqual(retryCanvas, failedCanvas);
  assert.equal(failedCanvas.replacement, retryCanvas);
  assert.deepEqual(retryCanvas.attributes, canvasAttributes);
  assert.equal(browser.root, root);
  assert.equal(root.hudCanvas, hudCanvas);
  assert.equal(state.environmentGenerators[0].disposals, 1);
  assert.equal(state.environmentGenerators[0].geometryDisposed, true);
  assert.equal(state.environmentGenerators[0].materialDisposed, true);
  assert.equal(state.environmentTargets.length, 0);
  assert.equal(browser.observers.length, 0);
  assert.equal(browser.frames.size, 0);
  browser.assertListenersRemoved();

  const cockpit = initCockpit(root, dependencies);
  assert.ok(cockpit);
  assert.equal(state.renderers.length, 2);
  assert.equal(state.renderers[1].canvas, retryCanvas);
  assert.equal(state.environmentTargets.length, 1);
  cockpit.dispose();
  assert.equal(state.renderers[1].disposals, 1);
  assert.equal(state.renderers[1].contextLosses, 0);
  assert.deepEqual(state.renderers[1].events, ['dispose']);
  assert.equal(root.sceneCanvas, retryCanvas);
  assert.equal(state.environmentGenerators[1].disposals, 1);
  assert.equal(state.environmentTargets[0].disposals, 1);
  browser.assertListenersRemoved();
});
