import { GpuRuntime } from "../vendor/cuda-webshader/runtime/runtime.js";
const $ = (id) => document.getElementById(id),
  canvas = $("scene"),
  n = 256;
const state = {
  softness: 0.72,
  water: 0.006,
  thickness: 8,
  seed: 17,
  wetness: 0.6,
  textureScale: 1,
  bump: 0.8,
  radius: 0.25,
  amount: 1,
  view: 0,
};
const camera = { yaw: 0.48, pitch: 0.67, distance: 6.7 };
const diag = (window.mudDiagnostics = {
  ready: false,
  errors: [],
  frames: 0,
  simulationSteps: 0,
  grid: n,
  area: [5, 5],
  frameTimes: [],
});
const bindings = new Map();
let rt,
  kernels = {},
  a,
  b,
  flux,
  solidFlux,
  structure,
  structureScratch,
  mixture,
  mixtureScratch,
  residue,
  objects,
  objectScratch,
  material,
  materialScratch,
  textureMap,
  pixels,
  ctx,
  selected = 0,
  held = 0,
  targetX = 0,
  targetZ = 0,
  tool = 0,
  brush = 0,
  bx = 0,
  bz = 0,
  brushVX = 0,
  brushVZ = 0,
  brushTime = 0,
  paused = false,
  demo = false,
  simTime = 0,
  busy = false,
  drag = null,
  last = 0,
  accumulator = 0,
  resetPending = false;
function fail(e) {
  const msg = String(e.message || e);
  diag.errors.push(msg);
  $("error").hidden = false;
  $("error").textContent = msg;
  $("loading").hidden = true;
  console.error(e);
}
for (const key of [
  "softness",
  "water",
  "thickness",
  "wetness",
  "textureScale",
  "bump",
  "radius",
  "amount",
])
  $(key).oninput = () => {
    state[key] = Number($(key).value);
    $(key + "Out").textContent =
      key === "thickness"
        ? state[key].toFixed(1) + " cm"
        : key === "water"
          ? Math.round(state[key] * 1000) + " mm"
          : key === "radius"
            ? state[key].toFixed(2) + " m"
            : state[key].toFixed(2);
  };
$("regenerate").onclick = () => {
  state.seed++;
  regeneratePending = true;
};
let regeneratePending = false;
$("view").onchange = () => (state.view = Number($("view").value));
document.querySelectorAll("[data-tool]").forEach(
  (btn) =>
    (btn.onclick = () => {
      tool = Number(btn.dataset.tool);
      document
        .querySelectorAll("[data-tool]")
        .forEach((b) => b.classList.toggle("active", b === btn));
    }),
);
$("pause").onclick = () => {
  paused = !paused;
  $("pause").textContent = paused ? "Resume" : "Pause";
};
$("reset").onclick = () => {
  resetPending = true;
  demo = false;
  held = 0;
  brush = 0;
  brushVX = brushVZ = 0;
};
$("demo").onclick = () => {
  demo = !demo;
  if (!demo) held = 0;
  $("demo").textContent = demo ? "Stop drag study" : "Run a slow drag study ↗";
  selected = 0;
};
$("quality").onchange = () => {
  canvas.width = Number($("quality").value);
  canvas.height = canvas.width === 640 ? 448 : canvas.width === 960 ? 640 : 832;
  if (pixels) {
    rt.destroyBuffer(pixels);
    pixels = rt.createBuffer(canvas.width * canvas.height * 4);
    bindings.clear();
  }
};
$("shot").onclick = () =>
  canvas.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "Mud-5x5.png";
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
function ray(e) {
  const r = canvas.getBoundingClientRect(),
    sx = (e.clientX - r.left - r.width * 0.5) / r.height,
    sy = (r.height * 0.5 - (e.clientY - r.top)) / r.height;
  const cy = Math.cos(camera.yaw),
    s = Math.sin(camera.yaw),
    cp = Math.cos(camera.pitch),
    sp = Math.sin(camera.pitch);
  const ro = [
    s * cp * camera.distance,
    sp * camera.distance,
    cy * cp * camera.distance,
  ];
  let rd = [
    -s * cp + cy * sx * 1.25 - s * sp * sy * 1.25,
    -sp + cp * sy * 1.25,
    -cy * cp - s * sx * 1.25 - cy * sp * sy * 1.25,
  ];
  const len = Math.hypot(...rd);
  rd = rd.map((x) => x / len);
  return { ro, rd };
}
function plane(e) {
  const { ro, rd } = ray(e);
  const t = (state.thickness / 100 - ro[1]) / rd[1];
  return [
    Math.max(-2.35, Math.min(2.35, ro[0] + rd[0] * t)),
    Math.max(-2.35, Math.min(2.35, ro[2] + rd[2] * t)),
  ];
}
canvas.oncontextmenu = (e) => e.preventDefault();
canvas.onpointerdown = async (e) => {
  if (!diag.ready) return;
  canvas.setPointerCapture(e.pointerId);
  demo = false;
  drag = {
    id: e.pointerId,
    x: e.clientX,
    y: e.clientY,
    orbit: e.button === 2 || e.altKey,
  };
  if (drag.orbit) return;
  const p = plane(e);
  bx = p[0];
  bz = p[1];
  if (tool) {
    brushTime = performance.now();
    brushVX = brushVZ = 0;
    brush = tool;
    return;
  }
  const token = drag;
  const data = await rt.read(objects);
  if (drag !== token) return;
  const { ro, rd } = ray(e);
  let best = Infinity;
  let found = -1;
  for (let j = 0; j < 4; j++) {
    const k = j * 8,
      delta = [data[k] - ro[0], data[k + 1] - ro[1], data[k + 2] - ro[2]],
      t = delta.reduce((sum, v, i) => sum + v * rd[i], 0);
    const d = Math.hypot(...delta.map((v, i) => v - rd[i] * t));
    if (d < data[k + 3] * 1.3 && t < best) {
      found = j;
      best = t;
    }
  }
  if (found >= 0) {
    selected = found;
    held = 1;
    targetX = p[0];
    targetZ = p[1];
  }
};
canvas.onpointermove = (e) => {
  if (!drag) return;
  if (drag.orbit) {
    camera.yaw -= (e.clientX - drag.x) * 0.006;
    camera.pitch = Math.max(
      0.3,
      Math.min(1.35, camera.pitch + (e.clientY - drag.y) * 0.006),
    );
    drag.x = e.clientX;
    drag.y = e.clientY;
  } else {
    const p = plane(e);
    const dt = Math.max(0.008, (performance.now() - brushTime) / 1000);
    brushVX = Math.max(-6, Math.min(6, (p[0] - bx) / dt));
    brushVZ = Math.max(-6, Math.min(6, (p[1] - bz) / dt));
    brushTime = performance.now();
    targetX = bx = p[0];
    targetZ = bz = p[1];
  }
};
function release() {
  drag = null;
  held = 0;
  brush = 0;
  brushVX = brushVZ = 0;
}
canvas.onpointerup = release;
canvas.onpointercancel = release;
canvas.onlostpointercapture = release;
canvas.onwheel = (e) => {
  e.preventDefault();
  camera.distance = Math.max(
    4.5,
    Math.min(12, camera.distance * Math.exp(e.deltaY * 0.001)),
  );
};
function dispatch(batch, name, buffers, scalars, count = n * n) {
  const key =
    name +
    ":" +
    Object.values(buffers)
      .map((b) => b.id)
      .join(",");
  let invocation = bindings.get(key);
  if (!invocation) {
    invocation = kernels[name].bind(buffers, scalars);
    bindings.set(key, invocation);
  } else invocation.setScalars(scalars);
  batch.dispatch(invocation, [Math.ceil(count / 128), 1, 1]);
}
function reset() {
  const batch = rt.batch();
  dispatch(
    batch,
    "initialize",
    { field: a, objects, material, mixture, residue, structure },
    {
      n,
      water: state.water,
      thickness: state.thickness / 100,
      seed: state.seed,
    },
  );
  batch.submit();
  simTime = 0;
  accumulator = 0;
  resetPending = false;
}
function generateTexture() {
  const batch = rt.batch();
  dispatch(
    batch,
    "texture_generate",
    { textureMap },
    { textureSize: 2048, seed: state.seed },
    2048 * 2048,
  );
  batch.submit();
  regeneratePending = false;
}
function step(batch, dt) {
  if (demo) {
    targetX = Math.sin(simTime * 0.65) * 1.55;
    targetZ = Math.sin(simTime * 0.95) * 1.1;
    held = 1;
    selected = 0;
  }
  dispatch(
    batch,
    "objects_step",
    { field: a, input: objects, output: objectScratch },
    { n, dt, selected, held, targetX, targetZ, softness: state.softness },
    4,
  );
  [objects, objectScratch] = [objectScratch, objects];
  dispatch(
    batch,
    "mud_flux",
    { field: a, objects, flux: solidFlux, mixture, structure },
    {
      n,
      dt,
      softness: state.softness,
      brush,
      bx,
      bz,
      radius: state.radius,
      brushVX,
      brushVZ,
      amount: state.amount,
    },
  );
  dispatch(
    batch,
    "material_transport",
    { field: a, flux: solidFlux, input: material, output: materialScratch },
    { n },
  );
  [material, materialScratch] = [materialScratch, material];
  dispatch(
    batch,
    "mixture_solid",
    { field: a, flux: solidFlux, input: mixture, output: mixtureScratch, structure, outputStructure: structureScratch },
    { n },
  );
  [mixture, mixtureScratch] = [mixtureScratch, mixture];
  [structure, structureScratch] = [structureScratch, structure];
  dispatch(
    batch,
    "mud_step",
    { input: a, output: b, objects, flux: solidFlux },
    {
      n,
      dt,
      softness: state.softness,
      brush,
      bx,
      bz,
      radius: state.radius,
      amount: state.amount,
    },
  );
  dispatch(
    batch,
    "water_flux",
    { field: b, objects, flux, mixture },
    { n, dt },
  );
  dispatch(
    batch,
    "mixture_water",
    { field: b, flux, input: mixture, output: mixtureScratch },
    { n },
  );
  [mixture, mixtureScratch] = [mixtureScratch, mixture];
  dispatch(batch, "water_step", { input: b, flux, output: a }, { n });
  dispatch(
    batch,
    "churn",
    { field: a, mixture, residue, structure, objects, solidFlux },
    {
      n,
      dt,
      brush,
      bx,
      bz,
      radius: state.radius,
      brushVX,
      brushVZ,
      amount: state.amount,
    },
  );
  if (brush >= 4 && brush <= 7)
    dispatch(
      batch,
      "material_edit",
      { material, field: a },
      { n, dt, brush, bx, bz, radius: state.radius, amount: state.amount, brushVX, brushVZ },
    );
  simTime += dt;
  diag.simulationSteps++;
}
async function frame(now) {
  if (!diag.ready || busy) {
    requestAnimationFrame(frame);
    return;
  }
  busy = true;
  const start = performance.now();
  try {
    if (resetPending) reset();
    if (regeneratePending) generateTexture();
    if (performance.now() - brushTime > 80) brushVX = brushVZ = 0;
    const elapsed = last ? Math.min(0.1, (now - last) / 1000) : 1 / 60;
    last = now;
    const batch = rt.batch();
    if (!paused) {
      accumulator = Math.min(0.1, accumulator + elapsed);
      let steps = 0;
      while (accumulator >= 1 / 120 && steps < 12) {
        step(batch, 1 / 120);
        accumulator -= 1 / 120;
        steps++;
      }
    }
    if (paused && drag && brush >= 4 && brush <= 7)
      dispatch(batch, "material_edit", { material, field: a },
        {n,dt:elapsed,brush,bx,bz,radius:state.radius,amount:state.amount,brushVX,brushVZ});
    dispatch(
      batch,
      "render",
      {
        field: a,
        materialMap: material,
        objects,
        textureMap,
        pixels,
        mixture,
        residue,
      },
      {
        n,
        textureSize: 2048,
        width: canvas.width,
        rows: canvas.height,
        ...camera,
        textureScale: state.textureScale,
        bump: state.bump,
        wetness: state.wetness,
        view: state.view,
        selected,
        time: simTime,
      },
      canvas.width * canvas.height,
    );
    batch.submit();
    const encoder = rt.device.createCommandEncoder();
    encoder.copyBufferToTexture(
      { buffer: pixels.gpuBuffer, bytesPerRow: canvas.width * 4 },
      { texture: ctx.getCurrentTexture() },
      [canvas.width, canvas.height],
    );
    rt.device.queue.submit([encoder.finish()]);
    await rt.idle();
    diag.frames++;
    const ms = performance.now() - start;
    diag.frameTimes.push(ms);
    if (diag.frameTimes.length > 120) diag.frameTimes.shift();
    diag.stats = { ...rt.stats };
    if (diag.frames % 20 === 0) {
      const avg =
        diag.frameTimes.reduce((x, y) => x + y, 0) / diag.frameTimes.length;
      $("fps").textContent =
        (1000 / Math.max(avg, elapsed * 1000)).toFixed(0) + " fps";
      diag.meanFrameMs = avg;
      $("fps").title = `GPU queue completion: ${avg.toFixed(2)} ms`;
      $("fps").dataset.completionMs = avg.toFixed(2);
      $("status").textContent = paused
        ? "Surface paused"
        : held
          ? "Dragging through wet soil"
          : brush
            ? "Editing surface"
            : "Mud settling · water flowing";
    }
  } catch (e) {
    fail(e);
    diag.ready = false;
  } finally {
    busy = false;
  }
  requestAnimationFrame(frame);
}
window.mudTest = {
  set(values) {
    Object.assign(state, values);
  },
  camera,
  async contactProbe() {
    while (busy) await new Promise((r) => setTimeout(r, 10));
    return Array.from(await rt.read(objects));
  },
  async snapshot() {
    while (busy) await new Promise((r) => setTimeout(r, 10));
    return {
      field: Array.from(await rt.read(a)),
      objects: Array.from(await rt.read(objects)),
      material: Array.from(await rt.read(material)),
      mixture: Array.from(await rt.read(mixture)),
      residue: Array.from(await rt.read(residue)),
      structure: Array.from(await rt.read(structure)),
      time: simTime,
    };
  },
  async advance(steps = 120, options = {}) {
    paused = true;
    while (busy) await new Promise((r) => setTimeout(r, 10));
    Object.assign(state, options);
    for (let base = 0; base < steps; base += 16) {
      const batch = rt.batch();
      for (let i = base; i < Math.min(steps, base + 16); i++)
        step(batch, 1 / 120);
      batch.submit();
      await rt.idle();
    }
  },
  brush(kind, x, z, vx = 0, vz = 0) {
    brushTime = performance.now();
    brushVX = vx;
    brushVZ = vz;
    brush = kind;
    bx = x;
    bz = z;
  },
  drag(x, z, id = 0) {
    selected = id;
    held = 1;
    targetX = x;
    targetZ = z;
  },
  release,
  async resetLayer(cm) {
    paused = true;
    while (busy) await new Promise((r) => setTimeout(r, 10));
    state.thickness = cm;
    $("thickness").value = cm;
    $("thicknessOut").textContent = cm.toFixed(1) + " cm";
    reset();
    await rt.idle();
  },
  regenerate() {
    regeneratePending = true;
  },
  reset() {
    resetPending = true;
  },
  pause(value = true) {
    paused = value;
  },
  get runtime() {
    return rt;
  },
};
async function init() {
  rt = await GpuRuntime.create({ onError: fail });
  diag.adapter = rt.describe();
  canvas.dataset.adapter = JSON.stringify(diag.adapter);
  for (const entry of [
    "texture_generate",
    "initialize",
    "objects_step",
    "mud_flux",
    "mud_step",
    "water_flux",
    "water_step",
    "material_edit",
    "material_transport",
    "mixture_solid",
    "mixture_water",
    "churn",
    "render",
  ]) {
    kernels[entry] = await rt.kernel(
      await (await fetch(`generated/${entry}.json`)).json(),
    );
    $("loading").textContent = `Preparing ${entry}…`;
  }
  a = rt.createBuffer(n * n * 16);
  b = rt.createBuffer(n * n * 16);
  flux = rt.createBuffer(n * n * 16);
  solidFlux = rt.createBuffer(n * n * 16);
  structure = rt.createBuffer(n*n*4);
  structureScratch = rt.createBuffer(n*n*4);
  mixture = rt.createBuffer(n * n * 16);
  mixtureScratch = rt.createBuffer(n * n * 16);
  residue = rt.createBuffer(n * n * 16);
  objects = rt.createBuffer(8 * 16);
  objectScratch = rt.createBuffer(8 * 16);
  material = rt.createBuffer(n * n * 16);
  materialScratch = rt.createBuffer(n * n * 16);
  textureMap = rt.createBuffer(2048 * 2048 * 16);
  pixels = rt.createBuffer(canvas.width * canvas.height * 4);
  ctx = canvas.getContext("webgpu");
  ctx.configure({
    device: rt.device,
    format: "rgba8unorm",
    alphaMode: "opaque",
    usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
  });
  reset();
  generateTexture();
  await rt.idle();
  diag.ready = true;
  $("loading").hidden = true;
  requestAnimationFrame(frame);
}
init().catch(fail);
