import {readSnapshot as getSnapshot} from "./browser-snapshot.mjs";
import { chromium } from "playwright";
import { writeFile, mkdir } from "node:fs/promises";
import { spawn } from "node:child_process";
let server;
try {
  await fetch("http://127.0.0.1:4325/src/mud.cu");
} catch {
  server = spawn(process.execPath, ["scripts/serve.mjs"], { stdio: "ignore" });
  for (let i = 0; i < 50; i++) {
    try {
      await fetch("http://127.0.0.1:4325/");
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
}
await mkdir("artifacts", { recursive: true });
const browser = await chromium.launch({
  channel: "msedge",
  headless: true,
  args: ["--enable-unsafe-webgpu"],
});
const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
page.on("console", (m) => {
  if (m.type() === "error") errors.push(m.text());
});
try {
  await page.goto("http://127.0.0.1:4325");
  await page.waitForFunction(
    () => window.mudDiagnostics?.ready || window.mudDiagnostics?.errors.length,
    {},
    { timeout: 120000 },
  );
  if ((await page.evaluate(() => window.mudDiagnostics.errors)).length)
    throw Error("GPU initialization failed");
  await page.waitForFunction(
    () => window.mudDiagnostics.frames > 30,
    {},
    { timeout: 90000 },
  );
  await page.evaluate(() => mudTest.pause());
  const before = await getSnapshot(page);
  const n=before.n;
  await page.evaluate(() => mudTest.advance(240));
  const after = await getSnapshot(page);
  let water0 = 0,
    water1 = 0,
    soil0 = 0,
    soil1 = 0,
    minH = 1,
    maxH = -1;
  for (let i = 0; i < before.field.length; i += 4) {
    water0 += before.field[i + 1] + before.mixture[i];
    water1 += after.field[i + 1] + after.mixture[i];
    soil0 += before.field[i] + before.mixture[i+1] + before.residue[i];
    soil1 += after.field[i] + after.mixture[i+1] + after.residue[i];
    minH = Math.min(minH, after.field[i]);
    maxH = Math.max(maxH, after.field[i]);
  }
  if (after.field.some((x) => !Number.isFinite(x)))
    throw Error("Nonfinite field");
  if (Math.abs(water1 - water0) / Math.max(water0, 1e-10) > 0.0001)
    throw Error("Water conservation failed");
  if (minH < -0.000001) throw Error("Mud penetrated concrete");
  const contactIndex =
    (Math.round((2.5 / 5) * (n-1)) * n +
      Math.round(((-1.15 + 2.5) / 5) * (n-1))) *
    4;
  if (after.field[contactIndex] > 0.06)
    throw Error("Contact failed to clear finite mud layer");
  for (let j = 0; j < 4; j++)
    if (after.objects[j * 8 + 1] < after.objects[j * 8 + 3] - 0.00001)
      throw Error("Object penetrated concrete");
  if (Math.abs(soil1 - soil0) / soil0 > 1e-5)
    throw Error("Solid volume conservation failed");
  await page.screenshot({ path: "artifacts/mud-settled.png" });
  await page.evaluate(() => mudTest.drag(1.45, -1.15));
  await page.evaluate(() => mudTest.advance(300));
  await page.evaluate(() => mudTest.release());
  const dragged = await getSnapshot(page);
  let uvDelta = 0,
    heightDelta = 0;
  for (let i = 0; i < after.field.length; i += 4) {
    uvDelta +=
      Math.abs(dragged.field[i + 2] - after.field[i + 2]) +
      Math.abs(dragged.field[i + 3] - after.field[i + 3]);
    heightDelta += Math.abs(dragged.field[i] - after.field[i]);
  }
  if (uvDelta < 1 || heightDelta < 1)
    throw Error("Drag did not deform soil and UVs");
  await page.waitForTimeout(250);
  await page.screenshot({ path: "artifacts/mud-drag.png" });
  // Release and settle: ruts should survive without continued contact.
  await page.evaluate(() => mudTest.advance(1200));
  const settled = await getSnapshot(page);
  if (settled.field.some((x) => !Number.isFinite(x)))
    throw Error("Long-run stability failed");
  const index =
    (Math.round(((0.0 + 2.5) / 5) * (n-1)) * n +
      Math.round(((-1.15 + 2.5) / 5) * (n-1))) *
    4;
  if (settled.field[index] > 0.07) throw Error("Released smear disappeared");
  // Material edits must change their own fields, not require a geometry rebuild.
  await page.evaluate(() => mudTest.brush(5, -0.8, -0.8));
  await page.evaluate(() => mudTest.advance(120));
  await page.evaluate(() => mudTest.brush(6, 0.8, 0.8));
  await page.evaluate(() => mudTest.advance(120));
  await page.evaluate(() => mudTest.release());
  const painted = await getSnapshot(page);
  let pigment = 0,
    normalPaint = 0;
  for (let i = 0; i < painted.material.length; i += 4) {
    pigment += painted.material[i];
    normalPaint +=
      Math.abs(painted.material[i + 2]) + Math.abs(painted.material[i + 3]);
  }
  if (pigment < 1 || normalPaint < 1)
    throw Error("Live material / normal editing failed");
  await page.evaluate(() => mudTest.brush(1, 0, -1));
  await page.evaluate(() => mudTest.advance(120));
  await page.evaluate(() => mudTest.release());
  const wet = await getSnapshot(page);
  let addedWater = 0;
  for (let i = 0; i < wet.field.length; i += 4)
    addedWater += wet.field[i + 1] + wet.mixture[i] - painted.field[i + 1] - painted.mixture[i];
  if (addedWater < 1) throw Error("Water brush failed");
  // Pick and move the first ball through the actual canvas pointer handlers.
  const projected = await page.evaluate((data) => {
    const c = mudTest.camera,
      r = document.getElementById("scene").getBoundingClientRect();
    const cy = Math.cos(c.yaw),
      s = Math.sin(c.yaw),
      cp = Math.cos(c.pitch),
      sp = Math.sin(c.pitch);
    function project(x, y, z) {
      const ox = s * cp * c.distance,
        oy = sp * c.distance,
        oz = cy * cp * c.distance;
      const p = [x - ox, y - oy, z - oz];
      const depth = -s * cp * p[0] - sp * p[1] - cy * cp * p[2];
      return {
        x:
          r.x +
          r.width * 0.5 +
          ((cy * p[0] - s * p[2]) / depth / 1.25) * r.height,
        y:
          r.y +
          r.height * 0.5 -
          ((-s * sp * p[0] + cp * p[1] - cy * sp * p[2]) / depth / 1.25) *
            r.height,
      };
    }
    return {
      start: project(data[0], data[1], data[2]),
      end: project(0.8, 0, -1.6),
    };
  }, wet.objects);
  await page.mouse.move(projected.start.x, projected.start.y);
  await page.mouse.down();
  await page.waitForTimeout(100);
  await page.mouse.move(projected.end.x, projected.end.y, { steps: 12 });
  await page.evaluate(() => mudTest.advance(120));
  await page.mouse.up();
  const picked = await getSnapshot(page);
  if (
    Math.hypot(
      picked.objects[0] - wet.objects[0],
      picked.objects[2] - wet.objects[2],
    ) < 0.3
  )
    throw Error("Canvas object picking / dragging failed");
  await page.selectOption("#view", "2");
  await page.waitForTimeout(100);
  await page.screenshot({ path: "artifacts/mud-normals.png" });
  await page.selectOption("#view", "3");
  await page.waitForTimeout(100);
  await page.screenshot({ path: "artifacts/mud-uv.png" });
  await page.selectOption("#view", "0");
  await page.waitForTimeout(100);
  await page.screenshot({ path: "artifacts/mud-painted.png" });
  // Smear brush moves finite mud and its coordinates while preserving volume.
  const preSmear = await getSnapshot(page);
  for (let k = 0; k < 4; k++) {
    await page.evaluate(
      (k) => mudTest.brush(8, -1.4 + k * 0.12, -1.2, 1.4, 0.2),
      k,
    );
    await page.evaluate(() => mudTest.advance(24));
  }
  await page.evaluate(() => mudTest.release());
  const smeared = await getSnapshot(page);
  let smearHeightDelta = 0,
    smearUvDelta = 0,
    preMass = 0,
    postMass = 0;
  for (let i = 0; i < smeared.field.length; i += 4) {
    smearHeightDelta += Math.abs(smeared.field[i] - preSmear.field[i]);
    smearUvDelta += Math.abs(smeared.field[i + 2] - preSmear.field[i + 2]);
    preMass += preSmear.field[i] + preSmear.mixture[i+1] + preSmear.residue[i];
    postMass += smeared.field[i] + smeared.mixture[i+1] + smeared.residue[i];
  }
  if (smearHeightDelta < 1 || smearUvDelta < 1)
    throw Error("Mud smear brush did not transport material");
  if (Math.abs(preMass - postMass) / preMass > 1e-5)
    throw Error("Mud smear brush lost solid volume");
  await page.waitForTimeout(150);
  await page.screenshot({
    path: "artifacts/mud-smear-concrete.png",
    fullPage: true,
  });
  // Changing the atlas must not regenerate the mud geometry or object positions.
  const textureImage0 = await page.locator("#scene").screenshot();
  await page.click("#regenerate");
  await page.waitForTimeout(200);
  const textureImage1 = await page.locator("#scene").screenshot();
  const regenerated = await getSnapshot(page);
  if (!regenerated.field.every((v, i) => v === smeared.field[i]))
    throw Error("Texture regeneration changed geometry");
  if (textureImage0.equals(textureImage1))
    throw Error("Regenerated atlas did not change rendered material");
  // 1 cm versus 20 cm: volume must scale by 20 and the concrete stays rigid.
  await page.evaluate(() => mudTest.resetLayer(1));
  const thin = await getSnapshot(page);
  await page.screenshot({
    path: "artifacts/mud-1cm-concrete.png",
    fullPage: true,
  });
  await page.evaluate(() => mudTest.advance(480));
  const thinSettled = await getSnapshot(page);
  if (thinSettled.field.some((v, i) => i % 4 === 0 && v < -0.000001))
    throw Error("Thin layer passed beneath concrete");
  for (let j = 0; j < 4; j++)
    if (
      thinSettled.objects[j * 8 + 1] <
      thinSettled.objects[j * 8 + 3] - 0.000001
    )
      throw Error("Thin layer body passed beneath concrete");
  await page.evaluate(() => mudTest.resetLayer(20));
  const thick = await getSnapshot(page);
  let thinMass = 0,
    thickMass = 0;
  for (let i = 0; i < thin.field.length; i += 4) {
    thinMass += thin.field[i];
    thickMass += thick.field[i];
  }
  const thicknessVolumeRatio = thickMass / thinMass;
  if (Math.abs(thicknessVolumeRatio - 20) > 0.0001)
    throw Error("Thickness cm control does not set actual volume");
  await page.evaluate(() => mudTest.advance(840));
  let previousContact=await page.evaluate(() => mudTest.contactProbe()), maxStationaryRise=0;
  for(let k=0;k<10;k++) {
    await page.evaluate(() => mudTest.advance(12));
    const current=await page.evaluate(() => mudTest.contactProbe());
    for(let j=0;j<4;j++) maxStationaryRise=Math.max(maxStationaryRise,current[j*8+1]-previousContact[j*8+1]);
    previousContact=current;
  }
  if(maxStationaryRise>.002) throw Error('Stationary thick-mud contact rebounded');
  await page.waitForTimeout(150);
  await page.screenshot({
    path: "artifacts/mud-20cm-concrete.png",
    fullPage: true,
  });
  await page.evaluate(() => mudTest.resetLayer(8));
  await page.evaluate(() => mudTest.advance(240));
  // Identical wet patches: stirring must mix more than leaving the water still.
  async function wetPatch(stir) {
    await page.evaluate(() => mudTest.resetLayer(8));
    await page.evaluate(() => mudTest.brush(1, 0, 1.1));
    await page.evaluate(() => mudTest.advance(120));
    await page.evaluate(() => mudTest.release());
    if (stir) await page.evaluate(() => mudTest.brush(8, 0, 1.1, 1.4, .3));
    await page.evaluate(() => mudTest.advance(120));
    await page.evaluate(() => mudTest.release());
    return await getSnapshot(page);
  }
  const resting = await wetPatch(false), churned = await wetPatch(true);
  function phaseMetrics(s) {
    let free=0, bound=0, sediment=0, kneading=0, stains=0;
    for(let i=0;i<s.field.length;i+=4) {
      free+=s.field[i+1]; bound+=s.mixture[i]; sediment+=s.mixture[i+1];
      kneading+=s.mixture[i+2]; stains+=s.residue[i];
    }
    return {free,bound,sediment,kneading,stains};
  }
  const phaseComparison={resting:phaseMetrics(resting),churned:phaseMetrics(churned)};
  const structureRest=resting.structure.reduce((a,b)=>a+b,0)/resting.structure.length;
  const structureChurned=churned.structure.reduce((a,b)=>a+b,0)/churned.structure.length;
  if(structureChurned>=structureRest-.00001) throw Error('Churning failed to weaken clay structure');
  if(phaseComparison.resting.free < 1) throw Error('Free water was absorbed everywhere');
  if(phaseComparison.churned.kneading <= phaseComparison.resting.kneading + 1)
    throw Error('Motion failed to knead clay');
  if(phaseComparison.churned.sediment <= phaseComparison.resting.sediment * 1.2)
    throw Error('Motion failed to suspend sediment');
  await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-churned-water.png',fullPage:true});
  await page.selectOption('#view','4'); await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-separated-phases.png',fullPage:true});
  await page.selectOption('#view','0');
  await page.evaluate(() => mudTest.advance(1200));
  const recovered=await getSnapshot(page);
  const structureRecovered=recovered.structure.reduce((a,b)=>a+b,0)/recovered.structure.length;
  if(structureRecovered<=structureChurned+.00001) throw Error('Mud strength failed to recover at rest');
  await page.evaluate(() => mudTest.brush(2,0,1.1));
  await page.evaluate(() => mudTest.advance(1200));
  await page.evaluate(() => mudTest.release());
  const cleared = await getSnapshot(page);
  await page.evaluate(() => mudTest.advance(600));
  const aged = await getSnapshot(page);
  let exposedStainCells=0, persistentStain=0;
  for(let i=0;i<cleared.field.length;i+=4) {
    if(cleared.field[i]<.001 && cleared.residue[i]>.000001) {
      exposedStainCells++; persistentStain+=aged.residue[i];
    }
  }
  if(exposedStainCells<10 || persistentStain<=0) throw Error('Cleared concrete lost its residue');
  await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-concrete-residue.png',fullPage:true});
  await page.selectOption('#view','5'); await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-residue-diagnostic.png',fullPage:true});
  await page.selectOption('#view','0');
  await page.evaluate(() => mudTest.resetLayer(8));
  await page.evaluate(() => mudTest.advance(240));
  // Actual pointer editing must work while paused and leave geometry untouched.
  const pausedBefore = await getSnapshot(page);
  async function groundPoint(x,z) {
    return await page.evaluate(([x,z]) => {
      const c=mudTest.camera,r=document.getElementById('scene').getBoundingClientRect();
      const cy=Math.cos(c.yaw),sy=Math.sin(c.yaw),cp=Math.cos(c.pitch),sp=Math.sin(c.pitch);
      const p=[x-sy*cp*c.distance,.08-sp*c.distance,z-cy*cp*c.distance];
      const d=-sy*cp*p[0]-sp*p[1]-cy*cp*p[2];
      return {x:r.x+r.width*.5+(cy*p[0]-sy*p[2])/d/1.25*r.height,
        y:r.y+r.height*.5-(-sy*sp*p[0]+cp*p[1]-cy*sp*p[2])/d/1.25*r.height};
    },[x,z]);
  }
  const editStart=await groundPoint(-.8,1), editEnd=await groundPoint(-.35,1.12);
  await page.click('[data-tool="6"]');
  await page.mouse.move(editStart.x,editStart.y); await page.mouse.down();
  await page.waitForTimeout(250); await page.mouse.up();
  const pausedNormal = await getSnapshot(page);
  let pausedNormalDelta=0;
  for(let i=0;i<pausedBefore.material.length;i+=4)
    pausedNormalDelta+=Math.abs(pausedBefore.material[i+2]-pausedNormal.material[i+2])+Math.abs(pausedBefore.material[i+3]-pausedNormal.material[i+3]);
  if(pausedNormalDelta<1) throw Error('Paused canvas normal editing failed');
  await page.selectOption('#view','2'); await page.waitForTimeout(100);
  const normalImageBefore=await page.locator('#scene').screenshot();
  await page.click('[data-tool="4"]');
  await page.mouse.move(editStart.x,editStart.y); await page.mouse.down();
  await page.mouse.move(editEnd.x,editEnd.y,{steps:20}); await page.mouse.up();
  const pausedUv = await getSnapshot(page);
  let pausedUvDelta=0;
  for(let i=0;i<pausedBefore.field.length;i+=4) {
    if(pausedBefore.field[i]!==pausedUv.field[i] || pausedBefore.field[i+1]!==pausedUv.field[i+1])
      throw Error('Paused material editing moved soil or water');
    pausedUvDelta+=Math.abs(pausedNormal.field[i+2]-pausedUv.field[i+2])+Math.abs(pausedNormal.field[i+3]-pausedUv.field[i+3]);
  }
  if(pausedUvDelta<.1) throw Error('Directional canvas UV editing failed');
  await page.waitForTimeout(150);
  const normalImageAfter=await page.locator('#scene').screenshot();
  if(normalImageBefore.equals(normalImageAfter)) throw Error('UV editing did not change rendered normals');
  await page.screenshot({path:'artifacts/mud-paused-uv-normals.png',fullPage:true});
  await page.selectOption('#view','0'); await page.click('[data-tool="0"]');
  await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-live-material-edits.png',fullPage:true});
  // Measure active simulation + render + presentation completion, not paused rendering.
  const performance = [];
  await page.evaluate(() => mudTest.pause(false));
  for (const [quality, moving] of [
    ["640", false],
    ["960", false],
    ["1280", false],
    ["960", true],
  ]) {
    if (moving) await page.click("#demo");
    await page.selectOption("#quality", quality);
    await page.waitForTimeout(250);
    const start = await page.evaluate(() => {
      mudDiagnostics.frameTimes = [];
      return {
        frames: mudDiagnostics.frames,
        time: performance.now(),
        steps: mudDiagnostics.simulationSteps,
        groups: mudDiagnostics.stats.bindGroupsCreated,
      };
    });
    await page.waitForFunction(
      (f) => mudDiagnostics.frames >= f + 120,
      start.frames,
      { timeout: 30000 },
    );
    const measurement = await page.evaluate((start) => {
      const d = mudDiagnostics,
        a = [...d.frameTimes].sort((x, y) => x - y);
      return {
        width: document.getElementById("scene").width,
        height: document.getElementById("scene").height,
        frames: d.frames - start.frames,
        simulationSteps: d.simulationSteps - start.steps,
        cadenceFps:
          ((d.frames - start.frames) * 1000) / (performance.now() - start.time),
        meanCompletionMs: a.reduce((s, x) => s + x, 0) / a.length,
        medianCompletionMs: a[Math.floor(a.length * 0.5)],
        p95CompletionMs: a[Math.floor(a.length * 0.95)],
        newBindGroups: d.stats.bindGroupsCreated - start.groups,
      };
    }, start);
    measurement.movingObject = moving;
    performance.push(measurement);
  }
  await page.selectOption("#quality", "960");
  await page.evaluate(() => mudTest.pause());
  const report = {
    structureRest,structureChurned,structureRecovered,maxStationaryRise,
    pausedNormalDelta, pausedUvDelta, pausedEditPreservesGeometry:true,
    phaseComparison, exposedStainCells, persistentStain,
    water0,
    water1,
    relativeWaterError: Math.abs(water1 - water0) / water0,
    relativeSoilError: Math.abs(soil1 - soil0) / soil0,
    minH,
    maxH,
    uvDelta,
    heightDelta,
    persistentRutDepth: 0.08 - settled.field[index],
    mudThicknessCm: 8,
    thicknessVolumeRatio,
    smearHeightDelta,
    smearUvDelta,
    textureRegenerationPreservesGeometry: true,
    textureResolution: [4096, 4096],
    textureLayers:3,physicsResolution:n,materialResolution:1024,
    concreteSupportPassed: true,
    pigment,
    normalPaint,
    addedWater,
    canvasDragPassed: true,
    performance,
    objects: dragged.objects,
    diagnostics: await page.evaluate(() => window.mudDiagnostics),
    errors,
  };
  await writeFile("artifacts/validation.json", JSON.stringify(report, null, 2));
  console.log(
    JSON.stringify(
      {
        ...report,
        diagnostics: {
          ready: report.diagnostics.ready,
          errors: report.diagnostics.errors,
          adapter: report.diagnostics.adapter,
          stats: report.diagnostics.stats,
        },
      },
      null,
      2,
    ),
  );
  if (errors.length) throw Error(errors.join("\n"));
} finally {
  await browser.close();
  if (server) server.kill();
}
