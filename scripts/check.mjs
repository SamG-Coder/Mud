import { readdir, readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
for (const directory of ["src", "scripts"]) {
  for (const file of await readdir(directory)) {
    if (/\.(m?js)$/.test(file)) execFileSync(process.execPath, ["--check", `${directory}/${file}`]);
  }
}
const lock = JSON.parse(await readFile("package-lock.json", "utf8"));
const manifest = JSON.parse(await readFile("package.json", "utf8"));
if (JSON.stringify(lock.packages[""].devDependencies) !== JSON.stringify(manifest.devDependencies))
  throw Error("Package lock does not match dependencies");
console.log("JavaScript syntax and dependency lock checked.");
