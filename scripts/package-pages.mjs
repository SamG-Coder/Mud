import { createHash } from "node:crypto";
import { KERNELS } from "../src/kernels.js";
import { readFile, writeFile, mkdir, copyFile, rm } from "node:fs/promises";
import { resolve, relative, dirname, sep } from "node:path";
await import("./build.mjs");
const root = resolve("."), destination = resolve("dist");
if (destination !== resolve(root, "dist")) throw Error("Unexpected output directory");
await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
async function copy(path) {
  await mkdir(dirname(resolve(destination, path)), { recursive: true });
  await copyFile(resolve(root, path), resolve(destination, path));
}
const modules = new Set();
async function moduleTree(path) {
  if (modules.has(path)) return;
  modules.add(path);
  const source = await readFile(resolve(root, path), "utf8");
  await copy(path);
  for (const match of source.matchAll(/(?:import|export)\s+(?:[^;"']*?\sfrom\s*)?["']([^"']+)["']/g)) {
    const dependency = match[1];
    if (!dependency.startsWith(".")) throw Error(`External browser import: ${path}: ${dependency}`);
    const target = resolve(root, dirname(path), dependency);
    if (!target.startsWith(root + sep)) throw Error(`Import leaves project: ${dependency}`);
    await moduleTree(relative(root, target).split(sep).join("/"));
  }
}
await moduleTree("src/main.js");
for (const path of ["index.html", "style.css", "LICENSE", "src/mud.cu", "vendor/cuda-webshader/LICENSE", "docs/mud-rheology.md"])
  await copy(path);
const entries = KERNELS;
for (const entry of entries) {
  const path = `generated/${entry}.json`;
  const artifact = JSON.parse(await readFile(path, "utf8"));
  if (artifact.name !== entry || !artifact.wgsl?.includes("@compute")) throw Error(`Invalid kernel: ${entry}`);
  await copy(path);
}
// Put the complete executable dependency graph under one content-derived path.
// A cached HTML page can never combine a cached host with new shader bindings.
const executablePaths = [...modules].sort().concat(entries.map(entry => `generated/${entry}.json`));
const hash = createHash("sha256");
for (const path of executablePaths) {
  hash.update(path); hash.update("\0");
  hash.update((await readFile(resolve(root, path), "utf8")).replace(/\r\n/g, "\n"));
}
const assetRoot = `build/${hash.digest("hex").slice(0, 20)}/`;
for (const path of executablePaths) {
  const target = resolve(destination, assetRoot, path);
  await mkdir(dirname(target), {recursive:true});
  await copyFile(resolve(root,path),target);
}
const html = (await readFile("index.html", "utf8"))
  .replace('src="src/main.js"', `src="${assetRoot}src/main.js"`)
  .replace('href="style.css"', `href="style.css?v=${assetRoot.split("/")[1]}"`);
await writeFile(resolve(destination,"index.html"),html);
await writeFile(resolve(destination, ".nojekyll"), "");
await writeFile(resolve(destination, "build-info.json"), JSON.stringify({
  commit: process.env.GITHUB_SHA || "local", assetRoot, kernels: entries, browserModules: [...modules].sort(),
}, null, 2));
console.log(`Pages package: ${entries.length} CUDA kernels, ${modules.size} browser modules; relative paths support /Mud/.`);
