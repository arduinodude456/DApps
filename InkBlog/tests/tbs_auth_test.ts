import { assertEquals, assertStringIncludes, assertNotEquals } from "jsr:@std/assert@1";
import { credentialsFrom, provisionSession, verifyTbsDevice } from "../supabase/functions/inkblog-tbs-auth/index.ts";
import type { SupabaseClient, User } from "npm:@supabase/supabase-js@2.57.4";

const ACCOUNT = "a489a3d0-8253-4aa7-8b1a-1a559e4ec4fb";
const DEVICE = "tbs_abcdefghijklmnopqrstu";
const SECRET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

Deno.test("credential headers are required and bounded by the TBS formats", () => {
  const good = new Request("https://example.test", { headers: {
    "x-tbs-account-id": ACCOUNT, "x-tbs-device-id": DEVICE, "x-tbs-device-secret": SECRET,
  } });
  assertEquals(credentialsFrom(good)?.accountId, ACCOUNT);
  assertEquals(credentialsFrom(new Request("https://example.test")), null);
  assertEquals(credentialsFrom(new Request("https://example.test", { headers: {
    "x-tbs-account-id": ACCOUNT, "x-tbs-device-id": DEVICE, "x-tbs-device-secret": "short",
  } })), null);
});

Deno.test("TBS device verification forwards identity only to existing verifier", async () => {
  const captured: { request?: Request } = {};
  const ok = await verifyTbsDevice({ accountId: ACCOUNT, deviceId: DEVICE, deviceSecret: SECRET }, "https://db.example", "sb_publishable_test", async (input, init) => {
    captured.request = new Request(input, init);
    return new Response(JSON.stringify({ snapshot: { revision: 0, state: {} } }), { status: 200, headers: { "content-type": "application/json" } });
  });
  assertEquals(ok, true);
  assertEquals(captured.request?.url, "https://db.example/functions/v1/tbs-account");
  assertEquals(captured.request?.headers.get("x-tbs-device-secret"), SECRET);
  assertEquals(await captured.request?.text(), JSON.stringify({ action: "state" }));
  const denied = await verifyTbsDevice({ accountId: ACCOUNT, deviceId: DEVICE, deviceSecret: SECRET }, "https://db.example", "key", async () => new Response("unauthorized", { status: 401 }));
  assertEquals(denied, false);
});

Deno.test("first TBS login creates a matching Auth user, profile, and scoped session without mail", async () => {
  const calls: string[] = [];
  const createdAttributes: { value?: Record<string, unknown> } = {};
  const profile: { row?: Record<string, unknown> } = {};
  const user = { id: ACCOUNT, email: `tbs-${ACCOUNT}@accounts.inkblog.invalid`, app_metadata: { inkblog_tbs_account_id: ACCOUNT }, user_metadata: {}, aud: "authenticated", created_at: "" } as unknown as User;
  const admin = {
    auth: { admin: {
      getUserById: async () => ({ data: { user: null }, error: { status: 404 } }),
      createUser: async (attributes: Record<string, unknown>) => { calls.push("create"); createdAttributes.value = attributes; return { data: { user }, error: null }; },
      generateLink: async (attributes: Record<string, unknown>) => { calls.push(`generate:${attributes.type}`); return { data: { properties: { hashed_token: "one-time-hash" } }, error: null }; },
    } },
    from: (table: string) => ({ upsert: async (row: Record<string, unknown>, options: Record<string, unknown>) => { calls.push(`upsert:${table}`); profile.row = row; assertEquals(options.ignoreDuplicates, true); return { error: null }; } }),
  } as unknown as SupabaseClient;
  const publicClient = { auth: { verifyOtp: async (params: Record<string, unknown>) => {
    calls.push(`verify:${params.type}`); assertEquals(params.token_hash, "one-time-hash");
    return { data: { session: { access_token: "scoped-access", refresh_token: "scoped-refresh", token_type: "bearer", expires_in: 3600, user } }, error: null };
  } } } as unknown as SupabaseClient;
  const result = await provisionSession(admin, publicClient, ACCOUNT, "Reader Name");
  assertEquals("error" in result, false);
  if ("error" in result) throw new Error(result.error);
  assertEquals(createdAttributes.value?.id, ACCOUNT);
  assertEquals(createdAttributes.value?.email_confirm, true);
  assertEquals(profile.row?.id, ACCOUNT);
  assertEquals(profile.row?.display_name, "Reader Name");
  assertEquals(result.session.tbs_account_id, ACCOUNT);
  assertEquals(result.session.access_token, "scoped-access");
  assertEquals(JSON.stringify(result.session).includes(SECRET), false);
  assertEquals(calls.join(","), "create,upsert:inkblog_profiles,generate:magiclink,verify:magiclink");
  assertStringIncludes(syntheticEmailForTest(ACCOUNT), ".invalid");
  assertNotEquals(createdAttributes.value?.password, "");
});

function syntheticEmailForTest(accountId: string): string { return `tbs-${accountId}@accounts.inkblog.invalid`; }

Deno.test("existing unrelated Auth UUID is never adopted as a TBS identity", async () => {
  let created = false;
  const admin = {
    auth: { admin: {
      getUserById: async () => ({ data: { user: { id: ACCOUNT, email: "reader@example.test", app_metadata: {} } }, error: null }),
      createUser: async () => { created = true; return { data: { user: null }, error: null }; },
    } },
  } as unknown as SupabaseClient;
  const publicClient = {} as SupabaseClient;
  const result = await provisionSession(admin, publicClient, ACCOUNT, "Reader");
  assertEquals("error" in result && result.status, 409);
  assertEquals(created, false);
});
