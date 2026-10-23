import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.57.4";

const MAX_BODY_BYTES = 4096;
const MAX_TBS_RESPONSE_BYTES = 160 * 1024;
const ACCOUNT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DEVICE_ID = /^tbs_[A-Za-z0-9_-]{16,80}$/;
const DEVICE_SECRET = /^[A-Za-z0-9_-]{32,128}$/;
const HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "apikey, authorization, content-type, x-client-info, x-tbs-account-id, x-tbs-device-id, x-tbs-device-secret",
  "access-control-allow-methods": "POST, OPTIONS",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

type TbsCredentials = { accountId: string; deviceId: string; deviceSecret: string };

function reply(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { ...HEADERS, "content-type": "application/json; charset=utf-8" } });
}
function fail(message: string, status = 400): Response { return reply({ error: { message } }, status); }
function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
function cleanText(value: unknown, maximum: number): string {
  return typeof value === "string" ? value.trim().replace(/[\u0000-\u001f\u007f]/g, "").slice(0, maximum) : "";
}

export function credentialsFrom(request: Request): TbsCredentials | null {
  const accountId = cleanText(request.headers.get("x-tbs-account-id"), 80).toLowerCase();
  const deviceId = cleanText(request.headers.get("x-tbs-device-id"), 96);
  const deviceSecret = cleanText(request.headers.get("x-tbs-device-secret"), 160);
  return ACCOUNT_ID.test(accountId) && DEVICE_ID.test(deviceId) && DEVICE_SECRET.test(deviceSecret)
    ? { accountId, deviceId, deviceSecret }
    : null;
}

async function boundedText(response: Response, maximum: number): Promise<string | null> {
  const declared = Number(response.headers.get("content-length") || 0);
  if (declared > maximum || !response.body) return null;
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    size += part.value.length;
    if (size > maximum) { await reader.cancel(); return null; }
    chunks.push(part.value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { return null; }
}

export async function verifyTbsDevice(
  credentials: TbsCredentials,
  supabaseUrl: string,
  publishableKey: string,
  fetcher: typeof fetch = fetch,
): Promise<boolean> {
  const response = await fetcher(`${supabaseUrl.replace(/\/+$/, "")}/functions/v1/tbs-account`, {
    method: "POST",
    headers: {
      "accept": "application/json",
      "content-type": "application/json",
      "apikey": publishableKey,
      "authorization": `Bearer ${publishableKey}`,
      "x-tbs-account-id": credentials.accountId,
      "x-tbs-device-id": credentials.deviceId,
      "x-tbs-device-secret": credentials.deviceSecret,
    },
    body: JSON.stringify({ action: "state" }),
  });
  if (!response.ok) { await response.body?.cancel(); return false; }
  const text = await boundedText(response, MAX_TBS_RESPONSE_BYTES);
  if (!text) return false;
  const payload = record(JSON.parse(text));
  return !!payload && !!record(payload.snapshot);
}

function syntheticEmail(accountId: string): string { return `tbs-${accountId}@accounts.inkblog.invalid`; }
function randomPassword(): string { return `${crypto.randomUUID()}${crypto.randomUUID()}${crypto.randomUUID()}`; }
function isTbsLinked(user: User | null, accountId: string): user is User {
  return !!user && user.id === accountId && user.app_metadata?.inkblog_tbs_account_id === accountId;
}

export async function provisionSession(
  admin: SupabaseClient,
  publicClient: SupabaseClient,
  accountId: string,
  displayName: string,
): Promise<{ session: Record<string, unknown>; user: User } | { error: string; status: number }> {
  if (!ACCOUNT_ID.test(accountId)) return { error: "Ungültiges TBS-Konto.", status: 400 };
  const name = cleanText(displayName, 80) || "Reader";
  const email = syntheticEmail(accountId);
  const existing = await admin.auth.admin.getUserById(accountId);
  let user: User | null = existing.data?.user ?? null;
  if (existing.error && existing.error.status !== 404) return { error: "InkBlog-Konto konnte nicht geprüft werden.", status: 503 };

  if (user && !isTbsLinked(user, accountId)) {
    return { error: "Die TBS-Identität kollidiert mit einem vorhandenen InkBlog-Konto.", status: 409 };
  }
  if (!user) {
    const created = await admin.auth.admin.createUser({
      id: accountId,
      email,
      password: randomPassword(),
      email_confirm: true,
      app_metadata: { inkblog_tbs_account_id: accountId, inkblog_auth_provider: "appdock_tbs" },
      user_metadata: { display_name: name },
    });
    if (created.error || !created.data.user) {
      // Two readers can register the same TBS account simultaneously. Read back
      // the winning insert, but never treat an unrelated UUID collision as TBS.
      const raced = await admin.auth.admin.getUserById(accountId);
      user = raced.data?.user ?? null;
      if (!isTbsLinked(user, accountId)) return { error: "InkBlog-Konto konnte nicht automatisch angelegt werden.", status: 503 };
    } else user = created.data.user;
  }
  if (!isTbsLinked(user, accountId)) return { error: "Die TBS-Identität konnte nicht bestätigt werden.", status: 503 };

  const profile = await admin.from("inkblog_profiles").upsert(
    { id: accountId, display_name: name, bio: "" },
    { onConflict: "id", ignoreDuplicates: true },
  );
  if (profile.error) return { error: "InkBlog-Profil konnte nicht angelegt werden.", status: 503 };

  // Admin.generateLink creates but does not send the magic-link email. Verify
  // its one-time hash server-side with the public client and return only the
  // resulting scoped, ordinary Supabase user session to this authenticated TBS device.
  const link = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = link.data?.properties?.hashed_token;
  if (link.error || !tokenHash) return { error: "InkBlog-Sitzung konnte nicht ausgestellt werden.", status: 503 };
  const verified = await publicClient.auth.verifyOtp({ token_hash: tokenHash, type: "magiclink" });
  const session = verified.data?.session;
  if (verified.error || !session || session.user.id !== accountId) return { error: "InkBlog-Sitzung konnte nicht bestätigt werden.", status: 503 };

  return {
    user: session.user,
    session: {
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      token_type: session.token_type,
      expires_in: session.expires_in,
      expires_at: session.expires_at,
      user: { id: session.user.id, email: session.user.email },
      tbs_account_id: accountId,
    },
  };
}

export async function handler(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") return new Response("ok", { headers: HEADERS });
  if (request.method !== "POST") return fail("Nur POST ist erlaubt.", 405);
  const length = Number(request.headers.get("content-length") || 0);
  if (length > MAX_BODY_BYTES) return fail("Die Anfrage ist zu groß.", 413);
  const credentials = credentialsFrom(request);
  if (!credentials) return fail("Für InkBlog ist ein gültiges TBS-Gerät erforderlich.", 401);

  const base = Deno.env.get("SUPABASE_URL"), secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publishable = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!base || !secret || !publishable) return fail("Der InkBlog-TBS-Dienst ist nicht konfiguriert.", 503);

  let body: Record<string, unknown> | null;
  try {
    const text = await boundedText(new Response(request.body), MAX_BODY_BYTES);
    if (!text) return fail("Ungültige oder zu große JSON-Anfrage.", 400);
    body = record(JSON.parse(text));
  } catch { return fail("Ungültige JSON-Anfrage.", 400); }
  if (!body) return fail("Die Anfrage muss ein JSON-Objekt enthalten.", 400);

  try {
    if (!await verifyTbsDevice(credentials, base, publishable)) return fail("Die TBS-Geräteanmeldung wurde abgelehnt.", 401);
    const admin = createClient(base, secret, { auth: { persistSession: false, autoRefreshToken: false } });
    const publicClient = createClient(base, publishable, { auth: { persistSession: false, autoRefreshToken: false } });
    const result = await provisionSession(admin, publicClient, credentials.accountId, cleanText(body.display_name, 80));
    if ("error" in result) return fail(result.error, result.status);
    return reply(result.session, 200);
  } catch {
    return fail("InkBlog konnte das TBS-Konto gerade nicht anmelden.", 503);
  }
}

if (import.meta.main) Deno.serve(handler);
