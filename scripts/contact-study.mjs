import {readSnapshot as getSnapshot} from "./browser-snapshot.mjs";
import {chromium} from 'playwright';
import {writeFile,mkdir} from 'node:fs/promises';
const browser=await chromium.launch({channel:'msedge',headless:true,args:['--enable-unsafe-webgpu']});
const page=await browser.newPage({viewport:{width:1440,height:1100}});
try {
  await page.goto('http://127.0.0.1:4325');
  await page.waitForFunction(()=>mudDiagnostics.ready || mudDiagnostics.errors.length);
  await page.evaluate(()=>mudTest.resetLayer(8));
  await page.evaluate(()=>mudTest.advance(240));
  const before=await getSnapshot(page);
  await page.evaluate(()=>mudTest.drag(-.8,-1.2));
  await page.evaluate(()=>mudTest.advance(180));
  const trajectory=[];
  for(let leg=0;leg<4;leg++) {
    for(let k=0;k<=24;k++) {
      const z=leg%2===0?-1.2+k*.1:1.2-k*.1;
      await page.evaluate(z=>mudTest.drag(-.8,z),z);
      await page.evaluate(()=>mudTest.advance(12));
      trajectory.push((await page.evaluate(()=>mudTest.contactProbe())).slice(0,8));
    }
  }
  await page.evaluate(()=>mudTest.release());
  await page.evaluate(()=>mudTest.advance(600));
  const after=await getSnapshot(page);
  function mass(s) {
    let solid=0,water=0;
    for(let i=0;i<s.field.length;i+=4) {
      solid+=s.field[i]+s.mixture[i+1]+s.residue[i];
      water+=s.field[i+1]+s.mixture[i];
    }
    return {solid,water};
  }
  const m0=mass(before),m1=mass(after);
  const solidError=Math.abs(m1.solid-m0.solid)/m0.solid,waterError=Math.abs(m1.water-m0.water)/m0.water;
  if(solidError>1e-4 || waterError>1e-4) throw Error('Reversing drag lost mass');
  if(after.field.some(v=>!Number.isFinite(v)) || trajectory.some(p=>p[1]<p[3]-.000001))
    throw Error('Reversing drag was unstable or penetrated concrete');
  let pathBefore=0,pathAfter=0,count=0;
  const n=before.n,x=Math.round((-.8+2.5)/5*(n-1));
  for(let z=Math.round(1.3/5*(n-1));z<=Math.round(3.7/5*(n-1));z++) {
    const i=(z*n+x)*4;
    pathBefore+=before.field[i];pathAfter+=after.field[i];count++;
  }
  const meanPermanentDepth=(pathBefore-pathAfter)/count;
  if(meanPermanentDepth<.001) throw Error('Back-and-forth movement erased the track');
  await page.waitForTimeout(150);await mkdir('artifacts',{recursive:true});
  await page.screenshot({path:'artifacts/mud-repeated-reversal.png',fullPage:true});
  const report={passes:4,secondsPerPass:2.5,settleSeconds:5,solidError,waterError,meanPermanentDepth,trajectory,errors:await page.evaluate(()=>mudDiagnostics.errors)};
  await writeFile('artifacts/contact-study.json',JSON.stringify(report,null,2));
  console.log(JSON.stringify({...report,trajectory:undefined},null,2));
  if(report.errors.length) throw Error(report.errors.join('\n'));
} finally {await browser.close();}
