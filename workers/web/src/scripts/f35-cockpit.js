/*
 * F-35 cockpit flight scene, rendered as the landing-page background.
 * Ported from a standalone three.js r128 page; three stays pinned to 0.128.x
 * because light intensities and color management changed in later majors.
 * Sound, hints, and CDN loading from the original were dropped: the CSP only
 * allows same-origin bundles and the background never receives pointer events.
 * Scheduling, motion preference, and lifecycle live in cockpit-controller.js.
 */
import * as THREE from 'three';
import { createSceneController } from './cockpit-controller.js';

/* Decorative cadence cap (#270). Measured in headless Chrome, 30 FPS roughly
   halves main-thread and GPU-process time versus 60 FPS with steady ~33 ms
   frame gaps; the slow flight motion and time-based head look stay smooth.
   Instrument pages repaint at 12 Hz underneath it. */
const MAX_FPS = 30;
const MFD_INTERVAL = 1 / 12;

/** One live scene per scene canvas; repeated init returns the same handle. */
const active = new WeakMap();

/**
 * Builds the scene inside `root`, draws its first frame, and returns its
 * controller ({ state, pause, resume, dispose, memory }). Returns null when
 * the canvases are missing or WebGL is unavailable.
 */
export function initCockpit(root = document) {
  const sceneCanvas = root.querySelector('[data-cockpit-scene]');
  const hudCanvas = root.querySelector('[data-cockpit-hud]');
  if (!(sceneCanvas instanceof HTMLCanvasElement) || !(hudCanvas instanceof HTMLCanvasElement)) return null;
  const existing = active.get(sceneCanvas);
  if (existing) return existing;

  /* ============================== helpers ============================== */
  const cnv = (w, h) => {
    const c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    return c;
  };
  const rand = (a, b) => a + Math.random() * (b - a);
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const D2R = Math.PI / 180;

  /* ============================== renderer ============================== */
  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas: sceneCanvas, antialias: true });
  } catch {
    return null; // WebGL unavailable; the loader keeps the static fallback.
  }
  // Function declarations below are hoisted; nothing runs until start().
  const controller = createSceneController({
    win: window, maxFps: MAX_FPS, step, draw, resize, dispose: disposeScene,
  });
  const { signal } = controller;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.75));
  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(0xcfe0ee, 9000, 42000);

  const camera = new THREE.PerspectiveCamera(70, 1, 0.05, 90000);
  const headRig = new THREE.Group();
  headRig.add(camera);
  const aircraft = new THREE.Group();
  aircraft.add(headRig);
  scene.add(aircraft);
  const BASE_PITCH = -0.10; // look slightly down: cockpit lower half, sky upper
  headRig.rotation.x = BASE_PITCH;

  /* ============================== lights ============================== */
  const SUN_DIR = new THREE.Vector3(-0.42, 0.52, -0.74).normalize();
  scene.add(new THREE.HemisphereLight(0xcfe2ff, 0x35383d, 0.9));
  const sun = new THREE.DirectionalLight(0xfff2dc, 1.55);
  sun.position.copy(SUN_DIR).multiplyScalar(60);
  scene.add(sun);
  scene.add(new THREE.AmbientLight(0x40464e, 0.35));

  /* ============================== sky dome ============================== */
  const skyMat = new THREE.ShaderMaterial({
    side: THREE.BackSide,
    depthWrite: false,
    uniforms: {
      top: { value: new THREE.Color(0x0d3c85) },
      mid: { value: new THREE.Color(0x4f8fd6) },
      hor: { value: new THREE.Color(0xd9e7f3) },
      low: { value: new THREE.Color(0x93a9bd) },
      sunDir: { value: SUN_DIR.clone() },
      sunCol: { value: new THREE.Color(0xfff3d8) },
    },
    vertexShader: `varying vec3 vW;
      void main(){vW=(modelMatrix*vec4(position,1.)).xyz;
      gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`,
    fragmentShader: `varying vec3 vW;
      uniform vec3 top,mid,hor,low,sunDir,sunCol;
      void main(){
        vec3 d=normalize(vW-cameraPosition);
        float h=clamp(d.y,-1.,1.);
        vec3 col=mix(hor,mid,smoothstep(0.02,0.22,h));
        col=mix(col,top,smoothstep(0.15,0.72,h));
        col=mix(col,low,smoothstep(0.0,0.22,-h));
        float s=max(dot(d,sunDir),0.);
        col+=sunCol*(pow(s,1400.)*9.0+pow(s,44.)*0.42+pow(s,4.5)*0.12);
        gl_FragColor=vec4(col,1.);
      }`,
  });
  scene.add(new THREE.Mesh(new THREE.SphereGeometry(32000, 40, 24), skyMat));

  /* sun glow sprite */
  (function () {
    const c = cnv(128, 128), g = c.getContext('2d');
    const gr = g.createRadialGradient(64, 64, 0, 64, 64, 64);
    gr.addColorStop(0, 'rgba(255,250,235,1)');
    gr.addColorStop(0.25, 'rgba(255,244,214,.85)');
    gr.addColorStop(0.6, 'rgba(255,236,190,.22)');
    gr.addColorStop(1, 'rgba(255,236,190,0)');
    g.fillStyle = gr;
    g.fillRect(0, 0, 128, 128);
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({
      map: new THREE.CanvasTexture(c),
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      transparent: true,
    }));
    sp.position.copy(SUN_DIR).multiplyScalar(26000);
    sp.scale.set(6200, 6200, 1);
    scene.add(sp);
  })();

  /* ============================== clouds ============================== */
  function cloudTexture() {
    const c = cnv(256, 256), g = c.getContext('2d');
    const n = 10 + Math.floor(Math.random() * 7);
    for (let i = 0; i < n; i++) {
      const x = rand(60, 196), y = rand(95, 175), r = rand(26, 58);
      const gr = g.createRadialGradient(x, y, 0, x, y, r);
      const a = rand(0.35, 0.6);
      gr.addColorStop(0, `rgba(255,255,255,${a})`);
      gr.addColorStop(0.65, `rgba(248,250,253,${a * 0.45})`);
      gr.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = gr;
      g.beginPath();
      g.arc(x, y, r, 0, 7);
      g.fill();
    }
    return new THREE.CanvasTexture(c);
  }
  const cloudTexs = [cloudTexture(), cloudTexture(), cloudTexture()];
  const clouds = [];
  const CLOUD = { x: 7500, zNear: 2600, zFar: -17000, speed: 245 };
  function spawnCloud(init) {
    const high = Math.random() < 0.10;
    const mat = new THREE.SpriteMaterial({
      map: cloudTexs[(Math.random() * 3) | 0],
      transparent: true,
      depthWrite: false,
      opacity: high ? rand(0.10, 0.18) : rand(0.4, 0.72),
      rotation: high ? rand(-0.06, 0.06) : rand(0, Math.PI * 2),
    });
    const s = new THREE.Sprite(mat);
    const w = high ? rand(2200, 4200) : rand(520, 1750);
    s.scale.set(w, w * (high ? 0.10 : rand(0.42, 0.6)), 1);
    s.position.set(
      rand(-CLOUD.x, CLOUD.x),
      high ? rand(700, 1900) : rand(-2300, -450),
      init ? rand(CLOUD.zFar, CLOUD.zNear) : rand(CLOUD.zFar, CLOUD.zFar + 2500),
    );
    scene.add(s);
    clouds.push(s);
  }
  for (let i = 0; i < 170; i++) spawnCloud(true);

  /* ============================== terrain ============================== */
  function groundTexture() {
    const S = 1024, c = cnv(S, S), g = c.getContext('2d');
    g.fillStyle = '#46603f';
    g.fillRect(0, 0, S, S);
    const cols = ['#4d6b3f', '#5d7a44', '#6e7f4a', '#7d8a55', '#4a5d3a', '#8a8f5e', '#556b45', '#9a8f63', '#57654a'];
    for (let i = 0; i < 420; i++) {
      const w = rand(18, 90), h = rand(18, 90), x = rand(-w, S), y = rand(-h, S);
      g.fillStyle = cols[(Math.random() * cols.length) | 0];
      g.globalAlpha = rand(0.5, 0.9);
      for (const ox of [0, S, -S]) for (const oy of [0, S, -S]) g.fillRect(x + ox, y + oy, w, h);
    }
    g.globalAlpha = 0.55;
    g.strokeStyle = '#6e7268';
    g.lineWidth = 2;
    for (let i = 0; i < 7; i++) { const p = rand(0, S); g.beginPath(); g.moveTo(0, p); g.lineTo(S, p); g.stroke(); }
    for (let i = 0; i < 7; i++) { const p = rand(0, S); g.beginPath(); g.moveTo(p, 0); g.lineTo(p, S); g.stroke(); }
    g.globalAlpha = 0.8;
    g.strokeStyle = '#3f5d6e';
    g.lineWidth = 7;
    g.beginPath();
    const x0 = rand(200, 800);
    for (let y = 0; y <= S; y += 16) (y === 0 ? g.moveTo : g.lineTo).call(g, x0 + Math.sin(y / S * Math.PI * 4) * 60, y);
    g.stroke();
    g.globalAlpha = 1;
    const t = new THREE.CanvasTexture(c);
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(7, 7);
    return t;
  }
  const groundTex = groundTexture();
  const ground = new THREE.Mesh(
    new THREE.PlaneGeometry(95000, 95000),
    new THREE.MeshStandardMaterial({ map: groundTex, roughness: 1, metalness: 0 }),
  );
  ground.rotation.x = -Math.PI / 2;
  ground.position.y = -4300;
  scene.add(ground);

  /* ============================== cockpit materials ============================== */
  const M = {
    panel: new THREE.MeshStandardMaterial({ color: 0x3a3e43, roughness: 0.95 }),
    panelDark: new THREE.MeshStandardMaterial({ color: 0x2b2e32, roughness: 0.95 }),
    bezel: new THREE.MeshStandardMaterial({ color: 0x121315, roughness: 0.5, metalness: 0.25 }),
    pad: new THREE.MeshStandardMaterial({ color: 0x232528, roughness: 1 }),
    frame: new THREE.MeshStandardMaterial({ color: 0x2b2e31, roughness: 0.6, metalness: 0.3 }),
    wall: new THREE.MeshStandardMaterial({ color: 0x27292c, roughness: 1 }),
    black: new THREE.MeshStandardMaterial({ color: 0x17191b, roughness: 1 }),
    seat: new THREE.MeshStandardMaterial({ color: 0x141618, roughness: 1 }),
    red: new THREE.MeshStandardMaterial({ color: 0xc63b22, roughness: 0.48, metalness: 0.08 }),
    redDark: new THREE.MeshStandardMaterial({ color: 0x7e2620, roughness: 0.8 }),
    strap: new THREE.MeshStandardMaterial({ color: 0x232629, roughness: 1 }),
  };
  const cp = new THREE.Group();
  aircraft.add(cp);
  function box(w, h, d, mat, x, y, z, rx, ry, rz) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
    m.position.set(x, y, z);
    if (rx) m.rotation.x = rx;
    if (ry) m.rotation.y = ry;
    if (rz) m.rotation.z = rz;
    cp.add(m);
    return m;
  }
  function plane(w, h, mat, x, y, z, rx, ry, rz) {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), mat);
    m.position.set(x, y, z);
    if (rx) m.rotation.x = rx;
    if (ry) m.rotation.y = ry;
    if (rz) m.rotation.z = rz;
    cp.add(m);
    return m;
  }

  /* ---- screen canvases / textures ---- */
  const leftC = cnv(820, 606), rightC = cnv(820, 606), standC = cnv(200, 150), stripC = cnv(700, 56);
  const leftT = new THREE.CanvasTexture(leftC), rightT = new THREE.CanvasTexture(rightC),
    standT = new THREE.CanvasTexture(standC), stripT = new THREE.CanvasTexture(stripC);
  const screenMat = (t) => new THREE.MeshBasicMaterial({ map: t });

  /* generic small switch-panel texture */
  function panelTexture(w, h) {
    const c = cnv(w, h), g = c.getContext('2d');
    g.fillStyle = '#33363a';
    g.fillRect(0, 0, w, h);
    let y = 10;
    while (y < h - 40) {
      const ph = rand(34, 72), m = 8;
      g.fillStyle = '#3b3f44';
      g.strokeStyle = '#191b1d';
      g.lineWidth = 2;
      g.fillRect(m, y, w - 2 * m, ph);
      g.strokeRect(m, y, w - 2 * m, ph);
      const n = 2 + ((Math.random() * 4) | 0);
      for (let i = 0; i < n; i++) {
        const sx = m + 14 + i * ((w - 2 * m - 24) / n), sy = y + ph / 2;
        g.fillStyle = '#202225';
        g.beginPath();
        g.arc(sx, sy, 5, 0, 7);
        g.fill();
        g.strokeStyle = '#8f969c';
        g.lineWidth = 2.4;
        g.beginPath();
        g.moveTo(sx, sy);
        g.lineTo(sx, sy + (Math.random() < 0.5 ? -8 : 8));
        g.stroke();
        g.fillStyle = '#9aa1a7';
        g.font = '6px sans-serif';
        g.textAlign = 'center';
        g.fillText('ON', sx, y + 8);
      }
      for (const cx of [m + 5, w - m - 5]) for (const cy of [y + 5, y + ph - 5]) {
        g.fillStyle = '#1c1e20';
        g.beginPath();
        g.arc(cx, cy, 2.5, 0, 7);
        g.fill();
      }
      y += ph + 9;
    }
    return new THREE.CanvasTexture(c);
  }
  /* ICP keypad texture */
  function keypadTexture() {
    const c = cnv(256, 160), g = c.getContext('2d');
    g.fillStyle = '#2e3135';
    g.fillRect(0, 0, 256, 160);
    for (let r = 0; r < 3; r++) for (let col = 0; col < 5; col++) {
      const x = 18 + col * 46, y = 16 + r * 46;
      g.fillStyle = '#1e2023';
      g.fillRect(x, y, 36, 34);
      g.strokeStyle = '#0e0f10';
      g.strokeRect(x, y, 36, 34);
      g.fillStyle = '#cfd5da';
      g.font = '10px monospace';
      g.textAlign = 'center';
      g.fillText(String((r * 5 + col + 1) % 10), x + 18, y + 21);
    }
    return new THREE.CanvasTexture(c);
  }
  /* yellow/black stripe texture (ejection handle) */
  function stripeTexture() {
    const c = cnv(64, 64), g = c.getContext('2d');
    g.fillStyle = '#111';
    g.fillRect(0, 0, 64, 64);
    g.fillStyle = '#e8c530';
    for (let i = -64; i < 128; i += 16) {
      g.beginPath();
      g.moveTo(i, 0);
      g.lineTo(i + 8, 0);
      g.lineTo(i + 8 - 64, 64);
      g.lineTo(i - 64, 64);
      g.closePath();
      g.fill();
    }
    const t = new THREE.CanvasTexture(c);
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(8, 1);
    return t;
  }

  /* ============================== cockpit build ============================== */
  /* main instrument panel + bezel + screens */
  box(1.06, 0.46, 0.05, M.panel, 0, -0.30, -0.80, -0.12);
  box(0.82, 0.34, 0.035, M.bezel, 0, -0.245, -0.765, -0.12);
  plane(0.366, 0.272, screenMat(leftT), -0.193, -0.245, -0.7448, -0.12);
  plane(0.366, 0.272, screenMat(rightT), 0.193, -0.245, -0.7448, -0.12);
  /* thin center divider */
  box(0.014, 0.30, 0.012, M.bezel, 0, -0.245, -0.746, -0.12);
  /* small panels either side of the big display */
  plane(0.10, 0.30, new THREE.MeshStandardMaterial({ map: panelTexture(128, 340), roughness: 0.9 }), -0.475, -0.29, -0.757, -0.12);
  plane(0.10, 0.30, new THREE.MeshStandardMaterial({ map: panelTexture(128, 340), roughness: 0.9 }), 0.475, -0.29, -0.757, -0.12);
  /* strip of small indicators above screens */
  box(0.60, 0.07, 0.02, M.bezel, 0, -0.052, -0.805, -0.12);
  plane(0.56, 0.05, screenMat(stripT), 0, -0.052, -0.7938, -0.12);
  /* glareshield */
  box(1.08, 0.055, 0.18, M.pad, 0, -0.020, -0.865, -0.05);
  (function () {
    const lip = new THREE.Mesh(new THREE.CylinderGeometry(0.030, 0.030, 1.06, 10, 1, false), M.pad);
    lip.rotation.z = Math.PI / 2;
    lip.position.set(0, -0.024, -0.78);
    cp.add(lip);
  })();
  /* ICP pedestal + standby display + keypad */
  box(0.22, 0.26, 0.16, M.panelDark, 0, -0.52, -0.70, -0.15);
  box(0.118, 0.092, 0.012, M.redDark, 0, -0.428, -0.6205, -0.15);
  plane(0.10, 0.075, screenMat(standT), 0, -0.428, -0.6135, -0.15);
  plane(0.17, 0.105, new THREE.MeshStandardMaterial({ map: keypadTexture(), roughness: 0.9 }), 0, -0.545, -0.607, -0.15);
  /* under-panel bulkhead + footwell + pedals */
  plane(1.06, 0.5, M.black, 0, -0.73, -0.70, -0.3);
  plane(1.2, 0.6, M.black, 0, -0.86, -0.35, -Math.PI / 2);
  box(0.10, 0.15, 0.02, M.wall, -0.11, -0.63, -0.60, 0.5);
  box(0.10, 0.15, 0.02, M.wall, 0.11, -0.63, -0.60, 0.5);
  /* side filler panels angling back from main panel */
  plane(0.36, 0.50, M.panelDark, -0.63, -0.32, -0.70, 0, -0.62);
  plane(0.36, 0.50, M.panelDark, 0.63, -0.32, -0.70, 0, 0.62);
  /* corner fillers between glareshield ends and canopy rails */
  plane(0.34, 0.24, M.pad, -0.62, -0.02, -0.82, 0, -0.55);
  plane(0.34, 0.24, M.pad, 0.62, -0.02, -0.82, 0, 0.55);
  /* canopy bow (arch) */
  (function () {
    const arc = Math.PI + 0.5;
    const bow = new THREE.Mesh(new THREE.TorusGeometry(0.76, 0.05, 12, 56, arc), M.frame);
    bow.position.set(0, -0.17, -0.98);
    bow.rotation.z = -0.25;
    cp.add(bow);
    const pad = new THREE.Mesh(new THREE.TorusGeometry(0.71, 0.028, 10, 56, arc), M.pad);
    pad.position.set(0, -0.17, -0.955);
    pad.rotation.z = -0.25;
    cp.add(pad);
  })();
  /* canopy side rails going aft */
  box(0.07, 0.06, 1.55, M.frame, -0.70, -0.09, -0.15, 0, -0.05);
  box(0.07, 0.06, 1.55, M.frame, 0.70, -0.09, -0.15, 0, 0.05);
  /* cockpit side walls */
  plane(2.2, 0.66, M.wall, -0.73, -0.46, -0.28, 0, Math.PI / 2);
  plane(2.2, 0.66, M.wall, 0.73, -0.46, -0.28, 0, -Math.PI / 2);
  /* side consoles with switch-panel tops */
  box(0.30, 0.06, 0.92, M.panelDark, -0.50, -0.40, -0.05);
  box(0.30, 0.06, 0.92, M.panelDark, 0.50, -0.40, -0.05);
  plane(0.29, 0.90, new THREE.MeshStandardMaterial({ map: panelTexture(256, 512), roughness: 0.9 }), -0.50, -0.3695, -0.05, -Math.PI / 2);
  plane(0.29, 0.90, new THREE.MeshStandardMaterial({ map: panelTexture(256, 512), roughness: 0.9 }), 0.50, -0.3695, -0.05, -Math.PI / 2);

  /* right side-stick (red grip) */
  const stick = new THREE.Group();
  stick.position.set(0.455, -0.37, -0.18);
  (function () {
    const base = new THREE.Mesh(new THREE.CylinderGeometry(0.030, 0.038, 0.05, 14), M.black);
    base.position.y = 0.02;
    stick.add(base);
    const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.011, 0.014, 0.10, 10), M.frame);
    shaft.position.y = 0.09;
    stick.add(shaft);
    const grip = new THREE.Mesh(new THREE.SphereGeometry(1, 18, 14), M.red);
    grip.scale.set(0.027, 0.050, 0.032);
    grip.position.set(0, 0.185, -0.004);
    stick.add(grip);
    const knob = new THREE.Mesh(new THREE.SphereGeometry(0.013, 12, 10), M.red);
    knob.position.set(-0.008, 0.228, -0.008);
    stick.add(knob);
    const rest = new THREE.Mesh(new THREE.SphereGeometry(0.016, 12, 10), M.red);
    rest.scale.set(1, 0.55, 1.2);
    rest.position.set(0.014, 0.15, 0.012);
    stick.add(rest);
  })();
  stick.rotation.x = -0.10;
  cp.add(stick);

  /* left throttle (red grip) */
  const thr = new THREE.Group();
  thr.position.set(-0.455, -0.365, -0.10);
  (function () {
    const rail = new THREE.Mesh(new THREE.BoxGeometry(0.075, 0.02, 0.34), M.black);
    rail.position.y = 0.01;
    thr.add(rail);
    const arm = new THREE.Mesh(new THREE.BoxGeometry(0.032, 0.11, 0.05), M.frame);
    arm.position.set(0, 0.07, -0.03);
    arm.rotation.x = -0.25;
    thr.add(arm);
    const grip = new THREE.Mesh(new THREE.SphereGeometry(1, 18, 14), M.red);
    grip.scale.set(0.034, 0.030, 0.064);
    grip.position.set(0, 0.125, -0.045);
    thr.add(grip);
    const hump = new THREE.Mesh(new THREE.SphereGeometry(0.018, 12, 10), M.red);
    hump.position.set(0, 0.142, -0.085);
    thr.add(hump);
  })();
  cp.add(thr);

  /* ejection handle (yellow/black loop) between knees */
  (function () {
    const loop = new THREE.Mesh(
      new THREE.TorusGeometry(0.055, 0.016, 10, 26),
      new THREE.MeshStandardMaterial({ map: stripeTexture(), roughness: 0.7 }),
    );
    loop.position.set(0, -0.545, -0.33);
    loop.rotation.x = -0.5;
    cp.add(loop);
    const post = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.07, 0.03), M.black);
    post.position.set(0, -0.615, -0.32);
    cp.add(post);
  })();
  /* seat pan + lap straps (visible looking down) */
  box(0.46, 0.06, 0.44, M.seat, 0, -0.68, 0.12);
  box(0.05, 0.02, 0.32, M.strap, -0.16, -0.585, 0.02, -0.35, 0, 0.45);
  box(0.05, 0.02, 0.32, M.strap, 0.16, -0.585, 0.02, -0.35, 0, -0.45);

  /* canopy glass */
  (function () {
    const geo = new THREE.SphereGeometry(1, 48, 24, 0, Math.PI * 2, 0, 1.72);
    const mat = new THREE.MeshPhongMaterial({
      color: 0xbcd6ea,
      transparent: true,
      opacity: 0.085,
      shininess: 90,
      specular: 0x9db8d0,
      side: THREE.BackSide,
      depthWrite: false,
    });
    const glass = new THREE.Mesh(geo, mat);
    glass.scale.set(0.88, 0.80, 1.95);
    glass.position.set(0, -0.14, -0.05);
    cp.add(glass);
  })();

  /* ============================== flight state ============================== */
  const S = {
    t: 0, roll: 0, pitch: 0, hdg: 87, kt: 452, alt: 24380, fuel: 11460, g: 1, vs: 0,
    n1: 92, n2: 97, egt: 760, ff: 8.2, thr: 0.82, hmd: true,
  };

  function turb(t, f1, f2, f3, amp) {
    return amp * (0.5 * Math.sin(t * f1) + 0.3 * Math.sin(t * f2 + 1.3) + 0.2 * Math.sin(t * f3 + 4.1));
  }

  /* ============================== MFD painters ============================== */
  const GRN = '#46ff8a', GRN2 = '#7dffa8', CYN = '#58cfff', AMB = '#ffb02e', WHT = '#e8f2f6';

  function tabs(g, w, labels, active, col) {
    const tw = w / labels.length;
    g.font = 'bold 12px Consolas,monospace';
    g.textAlign = 'center';
    labels.forEach((l, i) => {
      const x = i * tw;
      g.strokeStyle = i === active ? col : 'rgba(140,170,180,.5)';
      g.lineWidth = 1.4;
      g.strokeRect(x + 3, 5, tw - 6, 22);
      if (i === active) {
        g.fillStyle = 'rgba(70,255,138,.12)';
        g.fillRect(x + 3, 5, tw - 6, 22);
      }
      g.fillStyle = i === active ? col : 'rgba(150,180,190,.75)';
      g.fillText(l, x + tw / 2, 21);
    });
  }
  function osb(g, w, h, labels) {
    const tw = w / labels.length;
    g.font = 'bold 11px Consolas,monospace';
    g.textAlign = 'center';
    labels.forEach((l, i) => {
      g.strokeStyle = 'rgba(140,170,180,.5)';
      g.lineWidth = 1.2;
      g.strokeRect(i * tw + 8, h - 26, tw - 16, 20);
      g.fillStyle = 'rgba(170,200,210,.8)';
      g.fillText(l, i * tw + tw / 2, h - 12);
    });
  }
  function gauge(g, x, y, r, frac, label, val, col) {
    g.strokeStyle = 'rgba(70,255,138,.35)';
    g.lineWidth = 3;
    g.beginPath();
    g.arc(x, y, r, Math.PI * 0.75, Math.PI * 2.25);
    g.stroke();
    g.strokeStyle = col;
    g.lineWidth = 3.4;
    g.beginPath();
    g.arc(x, y, r, Math.PI * 0.75, Math.PI * 0.75 + frac * Math.PI * 1.5);
    g.stroke();
    const a = Math.PI * 0.75 + frac * Math.PI * 1.5;
    g.strokeStyle = WHT;
    g.lineWidth = 2;
    g.beginPath();
    g.moveTo(x, y);
    g.lineTo(x + Math.cos(a) * (r - 5), y + Math.sin(a) * (r - 5));
    g.stroke();
    g.fillStyle = col;
    g.font = 'bold 12px Consolas,monospace';
    g.textAlign = 'center';
    g.fillText(val, x, y + r + 16);
    g.fillStyle = 'rgba(160,255,190,.8)';
    g.font = '10px Consolas,monospace';
    g.fillText(label, x, y - r - 7);
  }

  /* F-35 planform (top view), right half; u,v in 0..1 */
  const PF = [[0.500, 0.030], [0.535, 0.070], [0.560, 0.130], [0.585, 0.210], [0.600, 0.300], [0.640, 0.360],
    [0.960, 0.560], [0.955, 0.610], [0.700, 0.680], [0.660, 0.700], [0.690, 0.740], [0.880, 0.830], [0.850, 0.870],
    [0.620, 0.870], [0.570, 0.905], [0.545, 0.930], [0.500, 0.935]];
  /* side profile */
  const SP = [[0.05, 0.560], [0.14, 0.520], [0.22, 0.470], [0.30, 0.430], [0.38, 0.450], [0.52, 0.462], [0.66, 0.470],
    [0.78, 0.300], [0.82, 0.310], [0.76, 0.475], [0.84, 0.500], [0.90, 0.505], [0.93, 0.530], [0.90, 0.560],
    [0.80, 0.585], [0.60, 0.610], [0.34, 0.620], [0.16, 0.590], [0.05, 0.560]];

  function paintLeft() {
    const g = leftC.getContext('2d'), w = 820, h = 606, t = S.t;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, w, h);
    g.fillStyle = '#04140c';
    g.fillRect(0, 0, w, h);
    g.strokeStyle = 'rgba(70,255,138,.4)';
    g.lineWidth = 2;
    g.strokeRect(1, 1, w - 2, h - 2);
    tabs(g, w, ['FCS', 'FUEL', 'STOR', 'TSD', 'DAS', 'EOTS', 'CNI', 'CKLST'], 1, GRN2);

    /* left column gauges */
    gauge(g, 66, 120, 34, 0.72 + turb(t, 0.9, 1.7, 2.9, 0.02), 'HYD A', '3050', GRN);
    gauge(g, 66, 226, 34, 0.70 + turb(t, 0.8, 1.5, 2.4, 0.02), 'HYD B', '3020', GRN);
    gauge(g, 66, 332, 34, 0.86, 'OXY', '88%', GRN);
    gauge(g, 66, 438, 34, 0.55 + 0.05 * Math.sin(t * 0.2), 'EPS', '28V', GRN);
    /* right column gauges */
    gauge(g, w - 66, 120, 34, 0.62, 'ECS', 'NORM', GRN);
    gauge(g, w - 66, 226, 34, 0.5 + 0.04 * Math.sin(t * 0.13), 'CAB', '8.1K', GRN);
    gauge(g, w - 66, 332, 34, 0.44, 'LIQ', 'OK', GRN);
    gauge(g, w - 66, 438, 34, 0.9, 'BATT', '25V', GRN);

    /* planform */
    const cx = w / 2, sx = 290, oy = 68, sy = 400;
    const map = (p) => [cx + (p[0] - 0.5) * sx, oy + p[1] * sy];
    g.save();
    g.strokeStyle = GRN;
    g.lineWidth = 2.2;
    g.shadowColor = GRN;
    g.shadowBlur = 8;
    g.beginPath();
    const m0 = map(PF[0]);
    g.moveTo(m0[0], m0[1]);
    for (let i = 1; i < PF.length; i++) { const p = map(PF[i]); g.lineTo(p[0], p[1]); }
    for (let i = PF.length - 1; i >= 0; i--) { const p = map([1 - PF[i][0], PF[i][1]]); g.lineTo(p[0], p[1]); }
    g.closePath();
    g.stroke();
    /* canopy */
    g.beginPath();
    g.ellipse(cx, oy + 0.165 * sy, 0.040 * sx, 0.075 * sy, 0, 0, 7);
    g.stroke();
    /* vertical tails (top view) */
    for (const s of [1, -1]) {
      g.beginPath();
      const q = [[0.585, 0.700], [0.640, 0.820], [0.612, 0.833], [0.560, 0.714]];
      q.forEach((p, i) => {
        const mp = map([0.5 + s * (p[0] - 0.5), p[1]]);
        (i ? g.lineTo : g.moveTo).call(g, mp[0], mp[1]);
      });
      g.closePath();
      g.stroke();
    }
    /* weapon bays */
    g.setLineDash([6, 4]);
    for (const s of [1, -1]) {
      const a = map([0.5 + s * 0.020, 0.40]), b = map([0.5 + s * 0.085, 0.62]);
      g.strokeRect(Math.min(a[0], b[0]), a[1], Math.abs(b[0] - a[0]), b[1] - a[1]);
    }
    g.setLineDash([]);
    /* stations */
    g.fillStyle = GRN;
    for (const s of [1, -1]) for (const st of [[0.72, 0.60], [0.80, 0.615], [0.88, 0.63]]) {
      const p = map([0.5 + s * (st[0] - 0.5), st[1]]);
      g.beginPath();
      g.arc(p[0], p[1], 3.4, 0, 7);
      g.fill();
    }
    g.restore();

    /* fuel block */
    g.textAlign = 'center';
    g.fillStyle = GRN2;
    g.font = 'bold 24px Consolas,monospace';
    g.fillText('FUEL  ' + Math.round(S.fuel).toLocaleString('en-US').replace(/,/g, ' ') + ' LB', cx, 505);
    g.font = '13px Consolas,monospace';
    g.fillStyle = GRN;
    const f1 = Math.round(S.fuel * 0.248), f2 = Math.round(S.fuel * 0.244);
    g.fillText('F1 ' + f1 + '   F2 ' + f2 + '   L WG ' + Math.round(S.fuel * 0.107) + '   R WG ' + Math.round(S.fuel * 0.105), cx, 527);
    g.fillStyle = AMB;
    g.fillText('GUN 182 RDS      AIM-120 × 4  RDY', cx, 549);

    osb(g, w, h, ['SWAP', 'NORM', 'QTY', 'TEST', 'MENU']);
    leftT.needsUpdate = true;
  }

  const noiseC = cnv(160, 80);
  (function () {
    const g = noiseC.getContext('2d');
    for (let i = 0; i < 2600; i++) {
      g.fillStyle = `rgba(${(Math.random() * 255) | 0},${(Math.random() * 255) | 0},${(Math.random() * 255) | 0},.14)`;
      g.fillRect(Math.random() * 160, Math.random() * 80, 1.5, 1.5);
    }
  })();

  function flirWindow(g, x, y, w, h, label, t, seed) {
    g.save();
    g.beginPath();
    g.rect(x, y, w, h);
    g.clip();
    const horY = y + h * 0.55 + Math.sin(t * 0.3 + seed) * 4;
    const grd = g.createLinearGradient(0, y, 0, y + h);
    grd.addColorStop(0, '#3d4145');
    grd.addColorStop(Math.max(0.05, (horY - y) / h - 0.02), '#2a2d30');
    grd.addColorStop(Math.min(0.95, (horY - y) / h), '#131414');
    grd.addColorStop(1, '#1d1f20');
    g.fillStyle = grd;
    g.fillRect(x, y, w, h);
    g.globalAlpha = 0.5;
    g.drawImage(noiseC, x - ((t * 37 + seed * 80) % 40), y - ((t * 23) % 20), w + 60, h + 40);
    g.globalAlpha = 1;
    /* crosshair + brackets */
    g.strokeStyle = 'rgba(230,240,235,.8)';
    g.lineWidth = 1.2;
    const cx = x + w / 2, cy = y + h / 2;
    g.beginPath();
    g.moveTo(cx - 12, cy);
    g.lineTo(cx - 4, cy);
    g.moveTo(cx + 4, cy);
    g.lineTo(cx + 12, cy);
    g.moveTo(cx, cy - 10);
    g.lineTo(cx, cy - 4);
    g.moveTo(cx, cy + 4);
    g.lineTo(cx, cy + 10);
    g.stroke();
    for (const [bx, by, dx, dy] of [[x + 6, y + 6, 10, 10], [x + w - 6, y + 6, -10, 10], [x + 6, y + h - 6, 10, -10], [x + w - 6, y + h - 6, -10, -10]]) {
      g.beginPath();
      g.moveTo(bx + dx, by);
      g.lineTo(bx, by);
      g.lineTo(bx, by + dy);
      g.stroke();
    }
    g.fillStyle = '#ffd75e';
    g.font = '10px Consolas,monospace';
    g.textAlign = 'left';
    g.fillText(label, x + 8, y + h - 8);
    g.textAlign = 'right';
    g.fillText('WHOT 1.0X', x + w - 8, y + h - 8);
    g.restore();
    g.strokeStyle = '#e9c93d';
    g.lineWidth = 2;
    g.strokeRect(x, y, w, h);
  }

  function paintRight() {
    const g = rightC.getContext('2d'), w = 820, h = 606, t = S.t;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, w, h);
    g.fillStyle = '#06141f';
    g.fillRect(0, 0, w, h);
    g.strokeStyle = 'rgba(88,207,255,.4)';
    g.lineWidth = 2;
    g.strokeRect(1, 1, w - 2, h - 2);
    tabs(g, w, ['ENG', 'FCS', 'ELEC', 'HYD', 'FUEL', 'DAS', 'TFLIR', 'WPN'], 0, CYN);

    /* left half: engine page */
    g.fillStyle = CYN;
    g.font = 'bold 14px Consolas,monospace';
    g.textAlign = 'left';
    g.fillText('ENGINE  F135-PW-100', 26, 58);
    const mx = (u) => 30 + u * 350, my = (v) => 96 + (v - 0.28) * (190 / 0.34);
    g.save();
    g.strokeStyle = CYN;
    g.lineWidth = 2;
    g.shadowColor = CYN;
    g.shadowBlur = 7;
    g.beginPath();
    SP.forEach((p, i) => {
      (i ? g.lineTo : g.moveTo).call(g, mx(p[0]), my(p[1]));
    });
    g.stroke();
    /* canopy stroke */
    g.beginPath();
    g.moveTo(mx(0.22), my(0.47));
    g.quadraticCurveTo(mx(0.30), my(0.415), mx(0.38), my(0.45));
    g.stroke();
    /* stabilator */
    g.beginPath();
    g.moveTo(mx(0.76), my(0.545));
    g.lineTo(mx(0.92), my(0.565));
    g.stroke();
    g.restore();
    /* engine highlight */
    g.strokeStyle = AMB;
    g.lineWidth = 2;
    g.strokeRect(mx(0.58), my(0.49), mx(0.90) - mx(0.58), my(0.60) - my(0.49));
    const fl = 0.6 + 0.4 * Math.sin(t * 7) + 0.2 * Math.sin(t * 13.7);
    g.strokeStyle = `rgba(255,176,46,${0.35 + 0.25 * fl})`;
    g.beginPath();
    g.moveTo(mx(0.93), my(0.53));
    g.lineTo(mx(0.93) + 14 + 6 * fl, my(0.545));
    g.lineTo(mx(0.93), my(0.56));
    g.stroke();

    /* bars */
    const bars = [['N1', S.n1, 110], ['N2', S.n2, 110], ['EGT', S.egt, 1000], ['FF', S.ff, 12]];
    bars.forEach((b, i) => {
      const bx = 48 + i * 88, by = 330, bw = 30, bh = 150, frac = clamp(b[1] / b[2], 0, 1);
      g.strokeStyle = 'rgba(88,207,255,.6)';
      g.lineWidth = 1.6;
      g.strokeRect(bx, by, bw, bh);
      const gr = g.createLinearGradient(0, by + bh, 0, by);
      gr.addColorStop(0, '#2fae62');
      gr.addColorStop(0.8, '#7ddd52');
      gr.addColorStop(1, '#e5d94a');
      g.fillStyle = gr;
      g.fillRect(bx + 2, by + bh - frac * (bh - 4) - 2, bw - 4, frac * (bh - 4));
      g.fillStyle = WHT;
      g.font = 'bold 13px Consolas,monospace';
      g.textAlign = 'center';
      g.fillText(typeof b[1] === 'number' && b[1] < 20 ? b[1].toFixed(1) : String(Math.round(b[1])), bx + bw / 2, by + bh + 18);
      g.fillStyle = CYN;
      g.font = '11px Consolas,monospace';
      g.fillText(b[0], bx + bw / 2, by - 8);
    });
    g.fillStyle = CYN;
    g.font = 'bold 13px Consolas,monospace';
    g.textAlign = 'left';
    g.fillText('THRUST ' + Math.round(S.thr * 100) + '%', 48, 530);
    g.fillText('NOZ ' + Math.round(62 - S.thr * 18) + '%', 210, 530);

    /* right half: sensor windows */
    flirWindow(g, 432, 52, 176, 136, 'EOTS IR', t, 0);
    flirWindow(g, 622, 52, 176, 136, 'DAS 6', t, 3.1);

    /* ICAWS status block */
    const px = 432, py = 214, pw = 366, ph = 330;
    g.strokeStyle = '#ff5544';
    g.lineWidth = 2;
    g.strokeRect(px, py, pw, ph);
    g.fillStyle = 'rgba(255,60,40,.22)';
    g.fillRect(px, py, pw, 26);
    g.fillStyle = '#ffd6ce';
    g.font = 'bold 13px Consolas,monospace';
    g.textAlign = 'left';
    g.fillText('ICAWS', px + 10, py + 18);
    g.textAlign = 'right';
    g.fillStyle = '#ffb3a6';
    g.fillText('MSG 0 / ADV 7', px + pw - 10, py + 18);
    const rows = [
      ['ENG........NORM', GRN2], ['FUEL FLOW..NORM', GRN2], ['HYD 1/2....NORM', GRN2],
      ['ELEC.......NORM', GRN2], ['OBOGS......NORM', GRN2], ['LINK 16..ACTIVE', GRN2],
      ['GPS/INS..ALIGNED', GRN2], ['XPDR.......STBY', AMB],
    ];
    g.font = '14px Consolas,monospace';
    g.textAlign = 'left';
    rows.forEach((r, i) => {
      if (r[1] === AMB && Math.floor(t * 1.2) % 4 === 0) return;
      g.fillStyle = r[1];
      g.fillText(r[0], px + 16, py + 52 + i * 24);
    });
    g.fillStyle = 'rgba(150,200,220,.55)';
    g.font = '11px Consolas,monospace';
    g.fillText('FLT TIME ' + (Math.floor(t / 60) + '').padStart(2, '0') + ':' + (Math.floor(t % 60) + '').padStart(2, '0'), px + 16, py + ph - 14);

    osb(g, w, h, ['SWAP', 'NORM', 'WHOT', 'AUTO', 'MENU']);
    rightT.needsUpdate = true;
  }

  function paintStandby() {
    const g = standC.getContext('2d'), w = 200, h = 150;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.fillStyle = '#101214';
    g.fillRect(0, 0, w, h);
    const cx = 100, cy = 70, r = 56;
    g.save();
    g.beginPath();
    g.arc(cx, cy, r, 0, 7);
    g.clip();
    g.translate(cx, cy);
    g.rotate(-S.roll);
    const po = S.pitch / D2R * 2.4;
    g.fillStyle = '#3a76c8';
    g.fillRect(-90, -90 + po, 180, 90);
    g.fillStyle = '#7a4a1e';
    g.fillRect(-90, po, 180, 90);
    g.strokeStyle = '#fff';
    g.lineWidth = 2;
    g.beginPath();
    g.moveTo(-90, po);
    g.lineTo(90, po);
    g.stroke();
    g.lineWidth = 1;
    g.font = '8px monospace';
    g.fillStyle = '#fff';
    g.textAlign = 'center';
    for (const p of [-20, -15, -10, -5, 5, 10, 15, 20]) {
      const y = po + p * 2.4, wq = p % 10 === 0 ? 24 : 12;
      g.beginPath();
      g.moveTo(-wq, y);
      g.lineTo(wq, y);
      g.stroke();
      if (p % 10 === 0) {
        g.fillText(String(Math.abs(p)), -wq - 9, y + 3);
        g.fillText(String(Math.abs(p)), wq + 9, y + 3);
      }
    }
    g.restore();
    /* fixed symbol */
    g.strokeStyle = '#ffb02e';
    g.lineWidth = 3;
    g.beginPath();
    g.moveTo(cx - 34, cy);
    g.lineTo(cx - 12, cy);
    g.lineTo(cx - 6, cy + 7);
    g.lineTo(cx, cy);
    g.lineTo(cx + 6, cy + 7);
    g.lineTo(cx + 12, cy);
    g.lineTo(cx + 34, cy);
    g.stroke();
    g.strokeStyle = '#666';
    g.lineWidth = 3;
    g.beginPath();
    g.arc(cx, cy, r + 1, 0, 7);
    g.stroke();
    g.fillStyle = GRN2;
    g.font = '10px Consolas,monospace';
    g.textAlign = 'center';
    g.fillText(Math.round(S.kt) + ' KT   ' + Math.round(S.alt) + ' FT', cx, h - 10);
    standT.needsUpdate = true;
  }

  function paintStrip() {
    const g = stripC.getContext('2d'), w = 700, h = 56;
    g.fillStyle = '#17181a';
    g.fillRect(0, 0, w, h);
    const labels = ['FIRE', 'MSTR', 'ARM', 'A/R', 'HOOK', 'JETT', 'NWS', 'PARK', 'LTS', 'IFF', 'ALT', 'ECM', 'GUN', 'TEST'];
    labels.forEach((l, i) => {
      const x = 14 + i * 49;
      g.fillStyle = i === 1 ? 'rgba(60,120,70,.55)' : '#222426';
      g.fillRect(x, 12, 38, 30);
      g.strokeStyle = '#0c0d0e';
      g.strokeRect(x, 12, 38, 30);
      g.fillStyle = i === 1 ? '#9fe8a8' : 'rgba(150,158,164,.5)';
      g.font = '8px Consolas,monospace';
      g.textAlign = 'center';
      g.fillText(l, x + 19, 30);
    });
    stripT.needsUpdate = true;
  }
  paintStrip();

  /* ============================== HMD overlay ============================== */
  const hg = hudCanvas.getContext('2d');
  let W = 0, H = 0, DPR = 1;
  function resize() {
    W = innerWidth;
    H = innerHeight;
    DPR = Math.min(devicePixelRatio || 1, 2);
    renderer.setSize(W, H, false);
    camera.aspect = W / H;
    camera.updateProjectionMatrix();
    hudCanvas.width = W * DPR;
    hudCanvas.height = H * DPR;
  }

  const _v = new THREE.Vector3();
  function toScreen(dir) {
    _v.copy(dir).multiplyScalar(20000).project(camera);
    return { x: (_v.x * 0.5 + 0.5) * W, y: (-_v.y * 0.5 + 0.5) * H, ok: _v.z < 1 && _v.z > -1 };
  }
  const UP = new THREE.Vector3(0, 1, 0);
  const _f = new THREE.Vector3(), _fh = new THREE.Vector3(), _rh = new THREE.Vector3(), _d = new THREE.Vector3();

  function drawHMD() {
    hg.setTransform(DPR, 0, 0, DPR, 0, 0);
    hg.clearRect(0, 0, W, H);
    if (!S.hmd) return;
    const col = 'rgba(150,255,170,.85)', dim = 'rgba(150,255,170,.55)';
    hg.strokeStyle = col;
    hg.fillStyle = col;
    hg.lineWidth = 1.5;
    hg.font = '600 15px Consolas,monospace';
    hg.shadowColor = 'rgba(120,255,150,.7)';
    hg.shadowBlur = 3;

    camera.getWorldDirection(_f);
    _fh.set(_f.x, 0, _f.z).normalize();
    _rh.crossVectors(_fh, UP).normalize(); // screen-right along horizon
    const cx = W / 2, cy = H / 2;

    /* horizon + pitch ladder */
    const p1 = toScreen(_d.copy(_fh).addScaledVector(_rh, -0.33));
    const p2 = toScreen(_d.copy(_fh).addScaledVector(_rh, 0.33));
    if (p1.ok && p2.ok) {
      const ang = Math.atan2(p2.y - p1.y, p2.x - p1.x);
      const mid = { x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 };
      hg.save();
      hg.translate(mid.x, mid.y);
      hg.rotate(ang);
      hg.beginPath();
      hg.moveTo(-W * 0.24, 0);
      hg.lineTo(-40, 0);
      hg.moveTo(40, 0);
      hg.lineTo(W * 0.24, 0);
      hg.stroke();
      hg.restore();
      for (const pd of [-10, -5, 5, 10, 15]) {
        const th = pd * D2R;
        const c = toScreen(_d.copy(_fh).multiplyScalar(Math.cos(th)).addScaledVector(UP, Math.sin(th)));
        if (!c.ok) continue;
        hg.save();
        hg.translate(c.x, c.y);
        hg.rotate(ang);
        hg.strokeStyle = dim;
        hg.setLineDash(pd < 0 ? [8, 6] : []);
        hg.beginPath();
        hg.moveTo(-70, 0);
        hg.lineTo(-22, 0);
        hg.moveTo(22, 0);
        hg.lineTo(70, 0);
        hg.stroke();
        hg.setLineDash([]);
        hg.fillStyle = dim;
        hg.font = '11px Consolas,monospace';
        hg.textAlign = 'left';
        hg.fillText(String(pd), 74, 4);
        hg.restore();
      }
    }

    hg.strokeStyle = col;
    hg.fillStyle = col;
    hg.textAlign = 'left';
    hg.font = '600 15px Consolas,monospace';

    /* flight-path marker (velocity vector: world -Z with slight droop) */
    const fp = toScreen(_d.set(0, Math.sin((S.pitch / D2R - 2.6) * D2R), -1).normalize());
    if (fp.ok) {
      hg.beginPath();
      hg.arc(fp.x, fp.y, 7, 0, 7);
      hg.stroke();
      hg.beginPath();
      hg.moveTo(fp.x - 19, fp.y);
      hg.lineTo(fp.x - 7, fp.y);
      hg.moveTo(fp.x + 7, fp.y);
      hg.lineTo(fp.x + 19, fp.y);
      hg.moveTo(fp.x, fp.y - 7);
      hg.lineTo(fp.x, fp.y - 13);
      hg.stroke();
    }
    /* waterline */
    hg.beginPath();
    hg.moveTo(cx - 14, cy);
    hg.lineTo(cx - 6, cy);
    hg.lineTo(cx, cy + 6);
    hg.lineTo(cx + 6, cy);
    hg.lineTo(cx + 14, cy);
    hg.stroke();

    /* airspeed / altitude boxes */
    const bx = cx - 268, by = cy - 158;
    hg.strokeRect(bx, by, 84, 26);
    hg.textAlign = 'right';
    hg.fillText(String(Math.round(S.kt)), bx + 72, by + 19);
    hg.textAlign = 'left';
    hg.font = '12px Consolas,monospace';
    hg.fillText('M ' + (S.kt / 652).toFixed(2), bx, by + 46);
    hg.fillText('G  ' + S.g.toFixed(1), bx, by + 64);
    hg.fillText('α  3.2', bx, by + 82);
    hg.font = '600 13px Consolas,monospace';
    hg.fillText('NAV', bx, by + 108);

    const ax = cx + 184;
    hg.font = '600 15px Consolas,monospace';
    hg.strokeRect(ax, by, 96, 26);
    hg.textAlign = 'right';
    hg.fillText(Math.round(S.alt).toLocaleString(), ax + 84, by + 19);
    hg.textAlign = 'left';
    hg.font = '12px Consolas,monospace';
    hg.fillText('VV ' + (S.vs >= 0 ? '+' : '') + Math.round(S.vs / 10) * 10, ax, by + 46);
    hg.fillText('RALT 24 300', ax, by + 64);

    /* heading tape */
    const ty = 64, ppd = 6.2;
    hg.font = '12px Consolas,monospace';
    hg.textAlign = 'center';
    const hdg = (S.hdg % 360 + 360) % 360;
    for (let d = -32; d <= 32; d++) {
      const hv = Math.round(hdg) + d;
      if ((hv % 5 + 5) % 5 !== 0) continue;
      const x = cx + (hv - hdg) * ppd;
      const major = (hv % 10 + 10) % 10 === 0;
      hg.strokeStyle = dim;
      hg.beginPath();
      hg.moveTo(x, ty);
      hg.lineTo(x, ty - (major ? 10 : 6));
      hg.stroke();
      if (major) hg.fillText((((hv % 360 + 360) % 360) / 10 | 0).toString().padStart(2, '0'), x, ty - 15);
    }
    hg.strokeStyle = col;
    hg.beginPath();
    hg.moveTo(cx, ty + 2);
    hg.lineTo(cx - 5, ty + 10);
    hg.lineTo(cx + 5, ty + 10);
    hg.closePath();
    hg.stroke();
    hg.strokeRect(cx - 24, ty + 12, 48, 20);
    hg.fillText(Math.round(hdg).toString().padStart(3, '0'), cx, ty + 27);

    hg.shadowBlur = 0;
  }

  /* ============================== input ============================== */
  let lookX = 0, lookY = 0, tgtX = 0, tgtY = 0;
  const coarsePointer = matchMedia('(pointer: coarse)').matches;
  if (!coarsePointer) {
    // Desktop: absolute mouse position steers the view. Skipped on touch
    // devices so iOS's synthetic mousemove after a tap can't snap the camera.
    addEventListener('mousemove', (e) => {
      tgtX = clamp((e.clientX / W - 0.5) * 2, -1, 1);
      tgtY = clamp((e.clientY / H - 0.5) * 2, -1, 1);
    }, { signal });
  }
  // Touch: dragging pans the cockpit view while the page content stays
  // pinned — deltas accumulate, so lifting the finger keeps the view put.
  let lastTX = null, lastTY = null;
  addEventListener('touchstart', (e) => {
    if (e.touches.length === 1) {
      lastTX = e.touches[0].clientX;
      lastTY = e.touches[0].clientY;
    }
  }, { passive: true, signal });
  addEventListener('touchmove', (e) => {
    const t = e.touches[0];
    if (!t || lastTX === null) return;
    tgtX = clamp(tgtX - (t.clientX - lastTX) * 2.2 / W, -1, 1);
    tgtY = clamp(tgtY - (t.clientY - lastTY) * 2.2 / H, -1, 1);
    lastTX = t.clientX;
    lastTY = t.clientY;
  }, { passive: true, signal });
  addEventListener('touchend', () => {
    lastTX = null;
    lastTY = null;
  }, { passive: true, signal });
  addEventListener('keydown', (e) => {
    if (e.key === 'h' || e.key === 'H') S.hmd = !S.hmd;
  }, { signal });

  /* ============================== main loop ============================== */
  let mfdAcc = 1; // paint the instruments on the very first step
  function step(dt) {
    const t = (S.t += dt);

    /* attitude: slow wandering bank + pitch + turbulence */
    const ta = 0.45 + 0.55 * Math.max(0, Math.sin(t * 0.017 + 2));
    const roll = (7.5 * Math.sin(t * 0.11) + 4 * Math.sin(t * 0.043 + 1.7)) * D2R + turb(t, 1.9, 3.7, 6.1, 0.13 * ta) * D2R;
    const pitch = (1.6 * Math.sin(t * 0.07 + 0.5) + 0.8 * Math.sin(t * 0.19) + 0.9) * D2R + turb(t, 1.4, 2.9, 5.3, 0.10 * ta) * D2R;
    S.roll = roll;
    S.pitch = pitch;
    aircraft.rotation.z = -roll;
    aircraft.rotation.x = pitch;

    /* head look */
    lookX = lerp(lookX, tgtX, 1 - Math.pow(0.002, dt));
    lookY = lerp(lookY, tgtY, 1 - Math.pow(0.002, dt));
    headRig.rotation.y = -lookX * 0.5;
    headRig.rotation.x = BASE_PITCH - lookY * 0.32 + turb(t, 2.2, 4.4, 7.7, 0.0016);

    /* flight params */
    S.kt = 452 + 6 * Math.sin(t * 0.05) + turb(t, 0.7, 1.9, 3.3, 1.2);
    const fps = S.kt * 1.68781;
    S.vs = fps * Math.sin(pitch) * 60;
    S.alt += fps * Math.sin(pitch) * dt;
    S.hdg += (1091 * Math.tan(roll) / Math.max(S.kt, 100)) * dt; // coordinated turn rate
    S.g = 1 / Math.cos(roll) + turb(t, 2.5, 5.1, 8.3, 0.03);
    S.thr = 0.80 + 0.10 * Math.sin(t * 0.031);
    S.n1 = 87 + 9 * S.thr + turb(t, 0.9, 2.1, 3.6, 0.3);
    S.n2 = 94 + 4 * S.thr;
    S.egt = 690 + 110 * S.thr + turb(t, 0.6, 1.4, 2.8, 3);
    S.ff = 5.5 + 3.6 * S.thr;
    S.fuel -= S.ff * 1000 / 3600 * dt;

    /* stick/throttle life */
    stick.rotation.z = -roll * 0.45;
    stick.rotation.x = -0.10 - (pitch - 0.9 * D2R) * 1.6;
    thr.position.z = -0.10 - (S.thr - 0.85) * 0.12;

    /* clouds stream past */
    for (const s of clouds) {
      s.position.z += CLOUD.speed * dt;
      if (s.position.z > CLOUD.zNear) {
        s.position.z = CLOUD.zFar + rand(0, 1800);
        s.position.x = rand(-CLOUD.x, CLOUD.x);
      }
    }
    /* terrain scroll */
    groundTex.offset.y += CLOUD.speed * dt * (7 / 95000);

    /* MFD repaint at 12 Hz; the remainder carries so the rate holds at any
       render cadence at or above it. */
    mfdAcc += dt;
    if (mfdAcc >= MFD_INTERVAL) {
      mfdAcc %= MFD_INTERVAL;
      paintLeft();
      paintRight();
      paintStandby();
    }
  }

  function draw() {
    renderer.render(scene, camera);
    drawHMD();
  }

  /* ============================== teardown ============================== */
  function disposeScene() {
    const textures = new Set([cloudTexs, groundTex, leftT, rightT, standT, stripT].flat());
    scene.traverse((object) => {
      object.geometry?.dispose();
      for (const material of [object.material ?? []].flat()) {
        if (material.map) textures.add(material.map);
        material.dispose();
      }
    });
    for (const texture of textures) texture.dispose();
    renderer.renderLists.dispose();
    renderer.dispose();
    hg.setTransform(1, 0, 0, 1, 0, 0);
    hg.clearRect(0, 0, hudCanvas.width, hudCanvas.height);
    clouds.length = 0;
    active.delete(sceneCanvas);
    if (root instanceof HTMLElement) root.dataset.cockpitState = 'static';
  }

  const handle = {
    get state() {
      return controller.state;
    },
    pause: controller.pause,
    resume: controller.resume,
    dispose: controller.dispose,
    /** GPU-side resource counts, for lifecycle checks. */
    memory: () => ({ ...renderer.info.memory, programs: renderer.info.programs?.length ?? 0 }),
  };
  active.set(sceneCanvas, handle);
  controller.start();
  return handle;
}
