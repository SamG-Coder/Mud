import { KERNELS } from "../src/kernels.js";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import {
  compile,
  serializableArtifact,
} from "../vendor/cuda-webshader/compiler/compiler.js";
await mkdir("generated", { recursive: true });
const source = await readFile("src/mud.cu", "utf8");
for (const entry of KERNELS) {
  const artifact = compile(source, { entry, workgroupSize: [128, 1, 1] });
  await writeFile(
    `generated/${entry}.json`,
    JSON.stringify(serializableArtifact(artifact)),
  );
  console.log(`${entry}: compiled`);
}
