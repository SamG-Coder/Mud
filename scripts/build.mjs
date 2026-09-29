import { readFile, writeFile, mkdir } from "node:fs/promises";
import {
  compile,
  serializableArtifact,
} from "../vendor/cuda-webshader/compiler/compiler.js";
await mkdir("generated", { recursive: true });
const source = await readFile("src/mud.cu", "utf8");
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
  const artifact = compile(source, { entry, workgroupSize: [128, 1, 1] });
  await writeFile(
    `generated/${entry}.json`,
    JSON.stringify(serializableArtifact(artifact)),
  );
  console.log(`${entry}: compiled`);
}
