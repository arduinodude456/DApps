import { Buffer } from "node:buffer";
import { PNG } from "npm:pngjs@7.0.0";
import jpeg from "npm:jpeg-js@0.4.4";

export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
export const MAX_PIXELS = 4_000_000;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const PATH = /^[0-9a-f-]{36}\/(?:[0-9a-f-]{36}\/)?[0-9a-f-]{36}\.png$/i;
export interface Upload {
  kind: "avatar" | "post";
  post_id?: string;
  alt_text: string;
  mime: "image/png" | "image/jpeg";
  bytes: Uint8Array;
  dither: boolean;
}
export function validateUpload(value: unknown): Upload {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Ungültiger Upload.");
  const input = value as Record<string, unknown>;
  if (input.kind !== "avatar" && input.kind !== "post") throw new Error("Ungültiger Bildtyp.");
  if (input.kind === "post" && (typeof input.post_id !== "string" || !UUID.test(input.post_id))) throw new Error("Eintrag fehlt.");
  const alt = typeof input.alt_text === "string" ? input.alt_text.trim() : "";
  if (alt.length > 500 || /[\u0000-\u001f]/.test(alt) || (input.kind === "post" && !alt)) throw new Error("Bitte einen Alt-Text angeben (maximal 500 Zeichen).");
  if (input.mime !== "image/png" && input.mime !== "image/jpeg") throw new Error("Nur PNG und JPEG sind erlaubt.");
  if (input.dither !== undefined && typeof input.dither !== "boolean") throw new Error("Ungültige Dithering-Option.");
  const encoded = input.image_base64;
  if (typeof encoded !== "string" || !encoded || encoded.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) throw new Error("Bilddaten ungültig oder größer als 2 MiB.");
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0)); } catch { throw new Error("Ungültiges Base64."); }
  if (bytes.length > MAX_IMAGE_BYTES) throw new Error("Das Bild ist zu groß.");
  dimensions(bytes, input.mime);
  return { kind: input.kind, post_id: input.post_id as string | undefined, alt_text: alt, mime: input.mime, bytes, dither: input.dither === true };
}
export function dimensions(bytes: Uint8Array, mime: string): [number, number] {
  let width = 0, height = 0;
  if (mime === "image/png") {
    if (bytes.length < 33 || ![137, 80, 78, 71, 13, 10, 26, 10].every((b, i) => bytes[i] === b) || String.fromCharCode(...bytes.slice(12, 16)) !== "IHDR") throw new Error("Ungültige PNG-Datei.");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    width = view.getUint32(16); height = view.getUint32(20);
  } else {
    if (bytes.length < 4 || bytes[0] !== 255 || bytes[1] !== 216) throw new Error("Ungültige JPEG-Datei.");
    let offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset++] !== 255) throw new Error("Ungültige JPEG-Struktur.");
      while (bytes[offset] === 255) offset++;
      const marker = bytes[offset++];
      if (marker === 0xd9 || marker === 0xda) break;
      if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      const length = (bytes[offset] << 8) | bytes[offset + 1];
      if (length < 2 || offset + length > bytes.length) throw new Error("Ungültige JPEG-Struktur.");
      if ([0xc0, 0xc1, 0xc2].includes(marker)) {
        if (length < 8) throw new Error("Ungültige JPEG-Abmessungen.");
        height = (bytes[offset + 3] << 8) | bytes[offset + 4];
        width = (bytes[offset + 5] << 8) | bytes[offset + 6]; break;
      }
      offset += length;
    }
  }
  if (!width || !height || width * height > MAX_PIXELS || width > 8192 || height > 8192) throw new Error("Maximal 4 Megapixel sind erlaubt.");
  return [width, height];
}
function nearestGray(value: number): number {
  return [0, 51, 102, 204, 255].reduce((best, gray) => Math.abs(value - gray) < Math.abs(value - best) ? gray : best);
}
export async function optimize(upload: Upload): Promise<{ bytes: Uint8Array; width: number; height: number }> {
  const [sourceWidth, sourceHeight] = dimensions(upload.bytes, upload.mime);
  const decoded = upload.mime === "image/png"
    ? PNG.sync.read(Buffer.from(upload.bytes), { checkCRC: true, skipRescale: false })
    : jpeg.decode(upload.bytes, { useTArray: true, formatAsRGBA: true, maxResolutionInMP: 4, maxMemoryUsageInMB: 64 });
  if (decoded.width !== sourceWidth || decoded.height !== sourceHeight) throw new Error("Ungültige Bildabmessungen.");
  const avatar = upload.kind === "avatar";
  const factor = Math.min(1, (avatar ? 128 : 800) / sourceWidth, (avatar ? 128 : 1000) / sourceHeight);
  const contentWidth = Math.max(1, Math.round(sourceWidth * factor)), contentHeight = Math.max(1, Math.round(sourceHeight * factor));
  const width = avatar ? 128 : contentWidth, height = avatar ? 128 : contentHeight;
  const gray = new Float32Array(width * height).fill(255);
  const left = Math.floor((width - contentWidth) / 2), top = Math.floor((height - contentHeight) / 2);
  function sample(x: number, y: number): number {
    const i = (Math.min(sourceHeight - 1, y) * sourceWidth + Math.min(sourceWidth - 1, x)) * 4;
    const alpha = decoded.data[i + 3] / 255;
    return (0.299 * decoded.data[i] + 0.587 * decoded.data[i + 1] + 0.114 * decoded.data[i + 2]) * alpha + 255 * (1 - alpha);
  }
  for (let y = 0; y < contentHeight; y++) for (let x = 0; x < contentWidth; x++) {
    const sx = Math.max(0, (x + 0.5) * sourceWidth / contentWidth - 0.5), sy = Math.max(0, (y + 0.5) * sourceHeight / contentHeight - 0.5);
    const x0 = Math.floor(sx), y0 = Math.floor(sy), dx = sx - x0, dy = sy - y0;
    gray[(top + y) * width + left + x] = sample(x0, y0) * (1 - dx) * (1 - dy) + sample(x0 + 1, y0) * dx * (1 - dy) + sample(x0, y0 + 1) * (1 - dx) * dy + sample(x0 + 1, y0 + 1) * dx * dy;
  }
  // Images retain their full aspect ratio. The avatar alone receives a circular seal mask.
  if (avatar) for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const radius = Math.hypot(x - 63.5, y - 63.5), angle = Math.atan2(y - 63.5, x - 63.5);
    const edge = 61 + Math.cos(angle * 36) * 1.2;
    if (radius > edge) gray[y * width + x] = 255;
    else if (radius > edge - 1.6 || (radius > 55 && radius < 56.5)) gray[y * width + x] = 0;
  }
  const values = new Uint8Array(gray.length);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const i = y * width + x, value = Math.min(255, Math.max(0, gray[i]));
    values[i] = upload.dither ? (value < 128 ? 0 : 255) : nearestGray(value);
    if (upload.dither) {
      const error = value - values[i];
      if (x + 1 < width) gray[i + 1] += error * 7 / 16;
      if (y + 1 < height) {
        if (x > 0) gray[i + width - 1] += error * 3 / 16;
        gray[i + width] += error * 5 / 16;
        if (x + 1 < width) gray[i + width + 1] += error / 16;
      }
    }
  }
  return { bytes: await grayscalePng(values, width, height, upload.dither), width, height };
}
function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(name: string, bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(bytes.length + 12), view = new DataView(out.buffer);
  view.setUint32(0, bytes.length); out.set(new TextEncoder().encode(name), 4); out.set(bytes, 8);
  view.setUint32(out.length - 4, crc32(out.subarray(4, out.length - 4))); return out;
}
export async function grayscalePng(values: Uint8Array, width: number, height: number, oneBit: boolean): Promise<Uint8Array> {
  const stride = oneBit ? Math.ceil(width / 8) : width;
  const scanlines = new Uint8Array((stride + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    if (oneBit) { if (values[y * width + x]) scanlines[y * (stride + 1) + 1 + (x >> 3)] |= 1 << (7 - (x & 7)); }
    else scanlines[y * (stride + 1) + 1 + x] = values[y * width + x];
  }
  const stream = new Blob([scanlines.buffer]).stream().pipeThrough(new CompressionStream("deflate"));
  const compressed = new Uint8Array(await new Response(stream).arrayBuffer());
  const header = new Uint8Array(13), view = new DataView(header.buffer);
  view.setUint32(0, width); view.setUint32(4, height); header[8] = oneBit ? 1 : 8;
  const pieces = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", compressed), chunk("IEND", new Uint8Array())];
  const output = new Uint8Array(pieces.reduce((sum, p) => sum + p.length, 0));
  let offset = 0; for (const piece of pieces) { output.set(piece, offset); offset += piece.length; } return output;
}
