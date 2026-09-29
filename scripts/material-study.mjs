import {readSnapshot} from "./browser-snapshot.mjs";
import {chromium} from "playwright";
import {writeFile,mkdir} from "node:fs/promises";
const browser=await chromium.launch({channel:"msedge",headless:true,args:["--enable-unsafe-webgpu"]});
const page=await browser.newPage({viewport:{width:1440,height:1250}});
const errors=[];page.on('pageerror',e=>errors.push(e.message));
try {
  await page.goto("http://127.0.0.1:4325");
  await page.waitForFunction(()=>mudDiagnostics.ready || mudDiagnostics.errors.length,{}, {timeout:120000});
  await page.evaluate(()=>mudTest.pause());
  await page.locator('#radius').fill('0.4');await page.locator('#amount').fill('2');
  async function prepare() {
    await page.evaluate(()=>mudTest.resetLayer(8));await page.evaluate(()=>mudTest.advance(240));
    await page.selectOption('#clayType','1');
    await page.evaluate(()=>mudTest.brush(5,-.6,1.1));await page.evaluate(()=>mudTest.advance(120));
    await page.selectOption('#clayType','2');
    await page.evaluate(()=>mudTest.brush(5,.35,1.1));await page.evaluate(()=>mudTest.advance(120));
    await page.evaluate(()=>mudTest.release());
  }
  function metrics(s) {
    let mix=0,swipe=0,maxMix=0,maxSwipe=0,normalizationError=0,minWeight=1;
    for(let i=0;i<s.colours.length;i+=4) {
      mix+=s.colours[i+3];swipe+=s.swipes[i+2];
      maxMix=Math.max(maxMix,s.colours[i+3]);maxSwipe=Math.max(maxSwipe,s.swipes[i+2]);
      normalizationError=Math.max(normalizationError,Math.abs(s.colours[i]+s.colours[i+1]+s.colours[i+2]-1));
      minWeight=Math.min(minWeight,s.colours[i],s.colours[i+1],s.colours[i+2]);
    }
    return {meanMix:mix/(s.colours.length/4),meanSwipe:swipe/(s.colours.length/4),maxMix,maxSwipe,normalizationError,minWeight};
  }
  await prepare();await page.waitForTimeout(150);
  await mkdir('artifacts',{recursive:true});
  await page.screenshot({path:'artifacts/mud-multiple-materials-before.png',fullPage:true});
  const initial=await page.evaluate(()=>mudTest.surfaceSnapshot());
  await page.evaluate(()=>mudTest.brush(8,-.15,1.1,.6,0));await page.evaluate(()=>mudTest.advance(60));
  await page.evaluate(()=>mudTest.release());
  const slow=metrics(await page.evaluate(()=>mudTest.surfaceSnapshot()));
  await prepare();
  await page.click('[data-tool="8"]');
  await page.evaluate(()=>mudTest.brush(8,-.15,1.1,4,0));await page.evaluate(()=>mudTest.advance(60));
  await page.evaluate(()=>mudTest.release());
  const physical=await readSnapshot(page);
  let peakDepth=0;for(let i=0;i<physical.field.length;i+=4) peakDepth=Math.max(peakDepth,physical.field[i]);
  if(peakDepth>.35) throw Error(`Fast smear created an excessive pile: ${peakDepth} m`);
  const fastSurface=await page.evaluate(()=>mudTest.surfaceSnapshot()),fast=metrics(fastSurface);
  if(fast.meanMix<slow.meanMix*1.3 || fast.meanSwipe<slow.meanSwipe*1.3) throw Error('Fast motion did not increase persistent mixing');
  if(fast.normalizationError>1e-5 || fast.minWeight<-.000001) throw Error('Material weights invalid');
  let colourDelta=0,coordinateDelta=0;
  for(let i=0;i<initial.colours.length;i+=4) {
    colourDelta+=Math.abs(initial.colours[i]-fastSurface.colours[i])+Math.abs(initial.colours[i+1]-fastSurface.colours[i+1]);
    coordinateDelta+=Math.abs(initial.coordinates[i]-fastSurface.coordinates[i])+Math.abs(initial.coordinates[i+1]-fastSurface.coordinates[i+1]);
  }
  if(colourDelta<1 || coordinateDelta<1) throw Error('Fast swipe failed to transport colours and UVs');
  await page.waitForTimeout(150);await page.screenshot({path:'artifacts/mud-fast-material-mixing.png',fullPage:true});
  await page.locator('#scene').screenshot({path:'artifacts/mud-layered-preview.png'});
  await page.selectOption('#view','6');await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-material-blend-map.png',fullPage:true});
  await page.selectOption('#view','7');await page.waitForTimeout(150);
  await page.screenshot({path:'artifacts/mud-swipe-map.png',fullPage:true});
  await page.selectOption('#view','0');
  await page.evaluate(()=>mudTest.advance(600));
  const persistent=metrics(await page.evaluate(()=>mudTest.surfaceSnapshot()));
  if(persistent.maxSwipe<fast.maxSwipe*.8) throw Error('Swipe history disappeared at rest');
  const beforeRegeneration=await page.evaluate(()=>mudTest.surfaceSnapshot());
  await page.click('#regenerate');await page.waitForTimeout(1000);
  const afterRegeneration=await page.evaluate(()=>mudTest.surfaceSnapshot());
  for(const key of ['colours','coordinates','swipes']) {
    if(beforeRegeneration[key].some((v,i)=>v!==afterRegeneration[key][i])) throw Error('Texture regeneration reset live surface state');
  }
  // A moving stroke must carry actual painted colour across a boundary.
  await page.evaluate(()=>mudTest.resetLayer(8));await page.evaluate(()=>mudTest.advance(240));
  await page.locator('#radius').fill('0.8');await page.selectOption('#clayType','2');
  await page.evaluate(()=>mudTest.brush(5,0,1.1));await page.evaluate(()=>mudTest.advance(120));
  await page.locator('#radius').fill('0.2');await page.selectOption('#clayType','1');
  await page.evaluate(()=>mudTest.brush(5,-.8,1.1));await page.evaluate(()=>mudTest.advance(30));
  await page.evaluate(()=>mudTest.release());
  const strokeBefore=await page.evaluate(()=>mudTest.surfaceSnapshot());
  function targetWarm(surface) {
    let sum=0,count=0;
    for(let z=0;z<surface.size;z++)for(let x=0;x<surface.size;x++) {
      const px=x*4*5/1023-2.5,pz=z*4*5/1023-2.5;
      if(px>.1&&px<.65&&Math.abs(pz-1.1)<.12){sum+=surface.colours[(z*surface.size+x)*4+1];count++;}
    }
    return sum/count;
  }
  await page.waitForTimeout(150);await page.locator('#scene').screenshot({path:'artifacts/mud-colour-stroke-before.png'});
  await page.locator('#radius').fill('0.3');
  for(let k=0;k<16;k++) {
    await page.evaluate(x=>mudTest.brush(8,x,1.1,2,0),-.8+k*.1);
    await page.evaluate(()=>mudTest.advance(6));
  }
  await page.evaluate(()=>mudTest.release());
  const strokeAfter=await page.evaluate(()=>mudTest.surfaceSnapshot());
  const colourTransfer={before:targetWarm(strokeBefore),after:targetWarm(strokeAfter)};
  if(colourTransfer.after-colourTransfer.before<.1)throw Error(`Moving swipe did not carry warm clay into silt: ${JSON.stringify(colourTransfer)}`);
  await page.waitForTimeout(150);await page.locator('#scene').screenshot({path:'artifacts/mud-colour-stroke-after.png'});
  const report={colourTransfer,slow,fast,persistent,peakDepth,colourDelta,coordinateDelta,textureRegenerationPreservesSurface:true,
    gpuMemoryMiB:await page.evaluate(()=>[...mudTest.runtime.buffers].reduce((a,b)=>a+b.size,0)/1048576),
    diagnostics:await page.evaluate(()=>({grid:mudDiagnostics.grid,materialGrid:mudDiagnostics.materialGrid,textureResolution:mudDiagnostics.textureResolution,textureLayers:mudDiagnostics.textureLayers,kernels:mudDiagnostics.stats.pipelineCompiles})),errors};
  await writeFile('artifacts/material-validation.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
  if(errors.length)throw Error(errors.join('\n'));
} finally {await browser.close();}

