import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { MAX_IMAGE_BYTES, PATH, UUID, optimize, validateUpload } from "./media.ts";

const MAX_BODY = Math.ceil(MAX_IMAGE_BYTES / 3) * 4 + 8192;
const HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};
function reply(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { ...HEADERS, "content-type": "application/json; charset=utf-8" } });
}
function fail(message: string, status = 400): Response { return reply({ error: { message } }, status); }
export async function readBody(request: Request): Promise<unknown> {
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) throw new Error("JSON erwartet.");
  if (Number(request.headers.get("content-length") || 0) > MAX_BODY) throw new Error("Die Anfrage ist zu groß.");
  if (!request.body) throw new Error("Upload fehlt.");
  const reader = request.body.getReader(), pieces: Uint8Array[] = []; let size = 0;
  while (true) {
    const result = await reader.read(); if (result.done) break;
    size += result.value.length;
    if (size > MAX_BODY) { await reader.cancel(); throw new Error("Die Anfrage ist zu groß."); }
    pieces.push(result.value);
  }
  const all = new Uint8Array(size); let at = 0;
  for (const part of pieces) { all.set(part, at); at += part.length; }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(all)); } catch { throw new Error("Ungültiges JSON."); }
}
export async function handler(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return new Response("ok", { headers: HEADERS });
  if (!["POST", "GET", "DELETE"].includes(request.method)) return fail("Nur GET, POST und DELETE sind erlaubt.", 405);
  const base = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY"), secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!base || !anon || !secret) return fail("Der Bilddienst ist nicht konfiguriert.", 503);
  const authorization = request.headers.get("authorization");
  // The gateway is intentionally not relied on: every write validates getUser().
  // Reads run the caller's RLS queries, never unconditionally through service role.
  const options = { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: authorization || `Bearer ${anon}` } } };
  const userDb = createClient(base, anon, options);
  const admin = createClient(base, secret, { auth: { persistSession: false, autoRefreshToken: false } });
  try {
    if (request.method === "GET") {
      const url = new URL(request.url), bucket = url.searchParams.get("bucket"), path = url.searchParams.get("path");
      if (!["inkblog-avatars", "inkblog-images"].includes(bucket || "") || !path || !PATH.test(path)) return fail("Ungültiger Bildpfad.");
      let authorized = false;
      if (bucket === "inkblog-avatars") {
        const { data, error } = await userDb.from("inkblog_profiles").select("id").eq("avatar_path", path).limit(1).maybeSingle();
        authorized = !error && !!data;
      } else {
        const { data, error } = await userDb.from("inkblog_post_images").select("id").eq("path", path).limit(1).maybeSingle();
        authorized = !error && !!data;
      }
      if (!authorized) return fail("Das Bild ist nicht verfügbar.", 404);
      const { data, error } = await admin.storage.from(bucket!).download(path);
      if (error || !data || data.size > 1024 * 1024) return fail("Das Bild ist nicht verfügbar.", 404);
      return new Response(data, { headers: { ...HEADERS, "content-type": "image/png" } });
    }
    if (!authorization?.startsWith("Bearer ")) return fail("Bitte zuerst anmelden.", 401);
    const { data: auth, error: authError } = await userDb.auth.getUser();
    if (authError || !auth.user) return fail("Die Sitzung ist abgelaufen. Bitte erneut anmelden.", 401);
    if (request.method === "DELETE") {
      const url = new URL(request.url), bucket = url.searchParams.get("bucket"), path = url.searchParams.get("path");
      if (!["inkblog-avatars", "inkblog-images"].includes(bucket || "") || !path || !PATH.test(path) || path.split("/")[0] !== auth.user.id) return fail("Nur eigene Bilder dürfen gelöscht werden.", 403);
      const removed = bucket === "inkblog-images"
        ? await userDb.from("inkblog_post_images").delete().eq("author_id", auth.user.id).eq("path", path)
        : await userDb.from("inkblog_profiles").update({ avatar_path: null }).eq("id", auth.user.id).eq("avatar_path", path);
      if (removed.error) return fail("Die Bildzuordnung konnte nicht entfernt werden.", 409);
      const { error } = await admin.storage.from(bucket!).remove([path]);
      if (error) return fail("Die gespeicherten Bilddaten konnten nicht entfernt werden.", 503);
      return reply({ ok: true });
    }
    const upload = validateUpload(await readBody(request));
    const { data: profile } = await userDb.from("inkblog_profiles").select("id").eq("id", auth.user.id).limit(1).maybeSingle();
    if (!profile) return fail("Bitte zuerst das Profil speichern.", 409);
    if (upload.kind === "post") {
      const { data: post, error } = await userDb.from("inkblog_posts").select("id,author_id").eq("id", upload.post_id!).limit(1).maybeSingle();
      if (error || !post || post.author_id !== auth.user.id) return fail("Bilder können nur eigenen Einträgen hinzugefügt werden.", 403);
      const { count } = await userDb.from("inkblog_post_images").select("id", { head: true, count: "exact" }).eq("post_id", upload.post_id!);
      if ((count || 0) >= 30) return fail("Maximal 30 Bilder pro Eintrag.", 409);
    }
    const output = await optimize(upload);
    if (output.bytes.length > 1024 * 1024) return fail("Das optimierte Bild ist zu groß.", 413);
    const id = crypto.randomUUID(), bucket = upload.kind === "avatar" ? "inkblog-avatars" : "inkblog-images";
    const path = upload.kind === "avatar" ? `${auth.user.id}/${id}.png` : `${auth.user.id}/${upload.post_id}/${id}.png`;
    if (!UUID.test(auth.user.id) || !PATH.test(path)) return fail("Ungültiger Bildpfad.");
    const { error: storedError } = await admin.storage.from(bucket).upload(path, new Blob([output.bytes.buffer as ArrayBuffer], { type: "image/png" }), { contentType: "image/png", upsert: false, cacheControl: "0", metadata: { width: output.width, height: output.height, inkblog_processed: true } });
    if (storedError) return fail("Das Bild konnte nicht gespeichert werden.", 503);
    const saved = upload.kind === "avatar"
      ? await userDb.from("inkblog_profiles").update({ avatar_path: path }).eq("id", auth.user.id).select("id").single()
      : await userDb.from("inkblog_post_images").insert({ id, post_id: upload.post_id, author_id: auth.user.id, path, alt_text: upload.alt_text, width: output.width, height: output.height }).select("id").single();
    if (saved.error || !saved.data) {
      await admin.storage.from(bucket).remove([path]);
      return fail("Die Bildzuordnung konnte nicht gespeichert werden.", 409);
    }
    return reply({ id: upload.kind === "post" ? id : undefined, path, width: output.width, height: output.height }, 201);
  } catch (error) {
    if (error instanceof Error && /(?:Ungültig|ungültig|erlaubt|Megapixel|Alt-Text|zu groß|fehlt|JSON|2 MiB)/.test(error.message)) return fail(error.message);
    return fail("Das Bild konnte nicht verarbeitet werden. Bitte PNG oder JPEG bis 4 Megapixel verwenden.");
  }
}
if (import.meta.main) Deno.serve(handler);
