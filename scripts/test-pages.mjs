import http from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,extname,sep} from 'node:path';
import {chromium} from 'playwright';
const root=resolve('dist'),info=JSON.parse(await readFile(resolve(root,'build-info.json'),'utf8'));
const server=http.createServer(async(req,res)=>{
  try {
    const url=new URL(req.url,'http://localhost');
    if(!url.pathname.startsWith('/Mud/'))throw Error('Outside site');
    const path=resolve(root,url.pathname.slice(5)||'index.html');
    if(!path.startsWith(root+sep))throw Error('Outside package');
    const body=await readFile(path);
    const type={'.html':'text/html','.js':'text/javascript','.json':'application/json','.css':'text/css'}[extname(path)]||'text/plain';
    res.writeHead(200,{'Content-Type':type,'Cache-Control':'public,max-age=86400'});res.end(body);
  }catch{res.writeHead(404);res.end('Not found');}
});
await new Promise(r=>server.listen(4326,'127.0.0.1',r));
const browser=await chromium.launch({channel:'msedge',headless:true,args:['--enable-unsafe-webgpu']});
try {
  const page=await browser.newPage(),errors=[],shaderRequests=[];
  page.on('pageerror',e=>errors.push(e.message));
  page.on('request',r=>{if(r.url().includes('/generated/'))shaderRequests.push(r.url());});
  await page.goto('http://127.0.0.1:4326/Mud/');
  for(let run=0;run<2;run++){
    if(run)await page.reload();
    await page.waitForFunction(()=>window.mudDiagnostics?.ready||window.mudDiagnostics?.errors.length,{}, {timeout:60000});
    const diagnostics=await page.evaluate(()=>mudDiagnostics);
    if(!diagnostics.ready||diagnostics.errors.length)throw Error(JSON.stringify(diagnostics.errors));
    if((await page.evaluate(()=>mudTest.runtime.stats)).pipelineCompiles!==info.kernels.length)throw Error('Missing pipeline');
    await page.evaluate(()=>mudTest.advance(120));
  }
  if(shaderRequests.length!==info.kernels.length*2||shaderRequests.some(url=>!url.includes('/'+info.assetRoot)))throw Error('Shader loading escaped pinned build');
  if(errors.length)throw Error(errors.join('\n'));
  const report={assetRoot:info.assetRoot,reloads:2,shaderRequests:shaderRequests.length,allShadersPinnedToBuild:true,errors};
  await mkdir('artifacts',{recursive:true});await writeFile('artifacts/pages-cache-validation.json',JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
}finally{await browser.close();await new Promise(r=>server.close(r));}
