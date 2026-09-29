export async function readSnapshot(page) {
  const result=await page.evaluate(()=>mudTest.snapshot(true));
  for(const key of ["field","objects","material","mixture","residue","structure"]) {
    const bytes=Buffer.from(result[key],"base64");
    result[key]=new Float32Array(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength));
  }
  return result;
}
