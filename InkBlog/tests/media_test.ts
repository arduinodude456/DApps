import { Buffer } from "node:buffer";
import { PNG } from "npm:pngjs@7.0.0";
import jpeg from "npm:jpeg-js@0.4.4";
import { dimensions, MAX_IMAGE_BYTES, optimize, PATH, validateUpload } from "../supabase/functions/inkblog-media/media.ts";
import { handler, readBody } from "../supabase/functions/inkblog-media/index.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value { if (!value) throw new Error(message); }
function rejects(run: () => unknown) { let rejected = false; try { run(); } catch { rejected = true; } assert(rejected); }
const POST = "11111111-1111-4111-8111-111111111111";
function image(width: number, height: number, color = [255, 0, 0, 255]): Uint8Array {
  const png = new PNG({ width, height });
  for (let i = 0; i < width * height; i++) png.data.set(color, i * 4);
  return PNG.sync.write(png);
}
function upload(bytes: Uint8Array, extra = {}): Record<string, unknown> {
  return { kind: "post", post_id: POST, alt_text: "Roter Test wird grau", mime: "image/png", image_base64: Buffer.from(bytes).toString("base64"), ...extra };
}
Deno.test("Upload validiert MIME, Base64, Alt-Text, UUID und Größenlimit", () => {
  const good = upload(image(2, 3));
  assert(validateUpload(good).bytes.length > 0);
  for (const extra of [{ mime: "image/svg+xml" }, { image_base64: "!!!!" }, { alt_text: "" }, { post_id: "../x" }, { dither: "true" }, { image_base64: "A".repeat(Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 4) }]) rejects(() => validateUpload({ ...good, ...extra }));
  rejects(() => validateUpload(null));
  assert(PATH.test(`${POST}/${POST}/${POST}.png`));
  assert(!PATH.test(`${POST}/../bad.png`));
});
Deno.test("Dekompressionsbomben werden vor dem Decode abgewiesen", () => {
  const bytes = image(1, 1), view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  view.setUint32(16, 6000); view.setUint32(20, 6000);
  rejects(() => dimensions(bytes, "image/png"));
  rejects(() => dimensions(new Uint8Array([255, 216, 255]), "image/jpeg"));
});
Deno.test("PNG wird dimensionsbegrenzt und auf die exakte E-Ink-Palette reduziert", async () => {
  const result = await optimize(validateUpload(upload(image(1000, 1200))));
  assert(result.width === 800 && result.height === 960);
  const decoded = PNG.sync.read(Buffer.from(result.bytes));
  for (let i = 0; i < decoded.data.length; i += 4) {
    assert([0, 51, 102, 204, 255].includes(decoded.data[i]));
    assert(decoded.data[i] === decoded.data[i + 1] && decoded.data[i] === decoded.data[i + 2]);
    assert(decoded.data[i + 3] === 255);
  }
  assert(result.bytes[24] === 8 && result.bytes[25] === 0, "PNG grayscale bitdepth8");
});
Deno.test("Dither-Ausgabe ist echte 1-Bit-Graustufen-PNG, auch bei ungerader Breite", async () => {
  const result = await optimize(validateUpload(upload(image(13, 9, [140, 140, 140, 255]), { dither: true })));
  assert(result.bytes[24] === 1 && result.bytes[25] === 0);
  const decoded = PNG.sync.read(Buffer.from(result.bytes));
  const pixels = new Set<number>();
  for (let i = 0; i < decoded.data.length; i += 4) { pixels.add(decoded.data[i]); assert([0, 255].includes(decoded.data[i])); }
  assert(pixels.size === 2);
});
Deno.test("Avatar bleibt 128px rund mit weißem Rand und schwarzem Siegel", async () => {
  const result = await optimize(validateUpload(upload(image(240, 180), { kind: "avatar", alt_text: "" })));
  assert(result.width === 128 && result.height === 128);
  const decoded = PNG.sync.read(Buffer.from(result.bytes));
  assert(decoded.data[0] === 255);
  assert(decoded.data[(64 * 128 + 2) * 4] === 0);
});
Deno.test("JPEG wird unterstützt, Metadaten werden nicht übernommen", async () => {
  const bytes = jpeg.encode({ width: 30, height: 20, data: Buffer.alloc(30 * 20 * 4, 180) }, 70).data;
  assert(dimensions(bytes, "image/jpeg")[0] === 30);
  const result = await optimize(validateUpload(upload(bytes, { mime: "image/jpeg" })));
  assert(result.width === 30 && result.height === 20 && result.bytes[25] === 0);
});
Deno.test("Transparenz wird auf Weiß reduziert, keine Farbinformation bleibt", async () => {
  const result = await optimize(validateUpload(upload(image(3, 2, [255, 0, 0, 0]))));
  const decoded = PNG.sync.read(Buffer.from(result.bytes));
  assert(decoded.data.every((b) => b === 255));
});
Deno.test("Anfrage wird streamingbegrenzt und ungeeignete Methoden werden abgelehnt", async () => {
  let rejected = false;
  try { await readBody(new Request("https://example.test", { method: "POST", headers: { "content-type": "application/json", "content-length": "9999999" }, body: "{}" })); } catch { rejected = true; }
  assert(rejected);
  const response = await handler(new Request("https://example.test", { method: "PUT" }));
  assert(response.status === 405);
});
