/**
 * AppDock Gmail Local Adapter.
 * Security contract: Google tokens remain in stateFile on this computer. The Kobo receives only
 * IDs plus From/Subject metadata after a deliberate authenticated HTTPS request.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.metadata";
const MAX_MESSAGES = 12;
const REQUEST_WINDOW_MS = 60_000;
const MAX_REQUESTS_PER_WINDOW = 12;
const TOKEN_MIN_LENGTH = 32;

function usage() {
  console.log("Usage: node gmail-adapter.mjs <authorize|start|token> [--config /absolute/path/config.json]");
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function base64url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

function createVerifier() {
  return base64url(crypto.randomBytes(64));
}

function timingSafeEqualText(left, right) {
  const leftBuffer = Buffer.from(String(left || ""));
  const rightBuffer = Buffer.from(String(right || ""));
  return leftBuffer.length === rightBuffer.length && crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function normaliseLimit(value) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? Math.min(MAX_MESSAGES, Math.max(1, parsed)) : MAX_MESSAGES;
}

function stripAddress(address = "") {
  return String(address).replace(/[\r\n\t]+/g, " ").trim().slice(0, 120);
}

function metadataFromMessage(message) {
  const headers = message?.payload?.headers;
  if (!message || typeof message.id !== "string" || !Array.isArray(headers)) return null;
  const values = Object.fromEntries(headers.map(({ name, value }) => [String(name || "").toLowerCase(), String(value || "")]));
  const from = stripAddress(values.from);
  const subject = stripAddress(values.subject);
  if (!/^[A-Za-z0-9_-]+$/.test(message.id) || !from || !subject) return null;
  return { id: message.id, from, subject };
}

function isAllowedClient(remoteAddress, allowedClientIPs) {
  if (!Array.isArray(allowedClientIPs) || allowedClientIPs.length === 0) return false;
  const address = String(remoteAddress || "").replace(/^::ffff:/, "");
  return allowedClientIPs.includes(address);
}

function peerAddress(request) {
  return request.socket?.remoteAddress || "";
}

async function readJson(file, label) {
  let raw;
  try {
    raw = await fsp.readFile(file, "utf8");
  } catch {
    throw new Error(`${label} could not be read: ${file}`);
  }
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error(`${label} is not valid JSON: ${file}`);
  }
}

async function writePrivateJson(file, value) {
  const target = path.resolve(file);
  const temporary = `${target}.${process.pid}.${crypto.randomBytes(5).toString("hex")}.tmp`;
  await fsp.mkdir(path.dirname(target), { recursive: true });
  await fsp.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await fsp.rename(temporary, target);
  await fsp.chmod(target, 0o600);
}

function configPath() {
  return path.resolve(argument("--config") || "config.json");
}

async function loadConfig() {
  const file = configPath();
  const config = await readJson(file, "Configuration");
  if (!config || typeof config !== "object" || typeof config.clientId !== "string" || !config.clientId.endsWith(".apps.googleusercontent.com")) {
    throw new Error("Configuration requires a Google Desktop OAuth clientId.");
  }
  if (!config.tls || typeof config.tls.keyPath !== "string" || typeof config.tls.certPath !== "string") {
    throw new Error("Configuration requires TLS keyPath and certPath.");
  }
  if (!config.listen || typeof config.listen.host !== "string" || !Number.isInteger(config.listen.port) || config.listen.port < 1 || config.listen.port > 65535) {
    throw new Error("Configuration requires a valid listen.host and listen.port.");
  }
  if (!Array.isArray(config.allowedClientIPs) || config.allowedClientIPs.length === 0 || !config.allowedClientIPs.every((item) => net.isIP(item) !== 0)) {
    throw new Error("Configuration requires at least one allowedClientIPs entry (the Kobo IPv4 or IPv6 address).");
  }
  if (typeof config.adapterToken !== "string" || config.adapterToken.length < TOKEN_MIN_LENGTH) {
    throw new Error("Configuration requires an adapterToken of at least 32 characters.");
  }
  config.stateFile = path.resolve(path.dirname(file), typeof config.stateFile === "string" ? config.stateFile : "gmail-adapter-state.json");
  return config;
}

async function formPost(url, parameters) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(parameters),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || !body) throw new Error("Google token exchange failed. Check the OAuth client and authorize again.");
  return body;
}

async function refreshAccessToken(config, state) {
  const refreshToken = state?.refreshToken;
  if (typeof refreshToken !== "string" || !refreshToken) throw new Error("No Gmail authorization is stored. Run authorize first.");
  const result = await formPost("https://oauth2.googleapis.com/token", {
    client_id: config.clientId,
    ...(typeof config.clientSecret === "string" && config.clientSecret ? { client_secret: config.clientSecret } : {}),
    refresh_token: refreshToken,
    grant_type: "refresh_token",
  });
  const next = {
    refreshToken: result.refresh_token || refreshToken,
    accessToken: result.access_token,
    expiresAt: Date.now() + Math.max(60, Number(result.expires_in || 3600)) * 1000,
  };
  await writePrivateJson(config.stateFile, next);
  return next;
}

async function accessToken(config) {
  const state = await readJson(config.stateFile, "OAuth state");
  if (typeof state.accessToken === "string" && Number(state.expiresAt) > Date.now() + 60_000) return state.accessToken;
  return (await refreshAccessToken(config, state)).accessToken;
}

async function googleJson(token, url) {
  const response = await fetch(url, { headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
  const body = await response.json().catch(() => null);
  if (!response.ok || !body) throw new Error("Gmail request failed. Reauthorize the local adapter if needed.");
  return body;
}

async function latestMetadata(config, limit) {
  const token = await accessToken(config);
  const listUrl = new URL("https://gmail.googleapis.com/gmail/v1/users/me/messages");
  listUrl.searchParams.append("labelIds", "INBOX");
  listUrl.searchParams.set("maxResults", String(limit));
  const listing = await googleJson(token, listUrl);
  const ids = Array.isArray(listing.messages) ? listing.messages.map((item) => item?.id).filter((id) => typeof id === "string") : [];
  const messages = [];
  for (const id of ids) {
    const detailUrl = new URL(`https://gmail.googleapis.com/gmail/v1/users/me/messages/${encodeURIComponent(id)}`);
    detailUrl.searchParams.set("format", "METADATA");
    detailUrl.searchParams.append("metadataHeaders", "From");
    detailUrl.searchParams.append("metadataHeaders", "Subject");
    const message = metadataFromMessage(await googleJson(token, detailUrl));
    if (message) messages.push(message);
  }
  return messages;
}

function sendJson(response, status, value) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" });
  response.end(JSON.stringify(value));
}

function requestLimiter() {
  const requests = new Map();
  return (remote) => {
    const now = Date.now();
    const history = (requests.get(remote) || []).filter((time) => time > now - REQUEST_WINDOW_MS);
    if (history.length >= MAX_REQUESTS_PER_WINDOW) return false;
    history.push(now);
    requests.set(remote, history);
    return true;
  };
}

async function authorize(config) {
  const verifier = createVerifier();
  const challenge = crypto.createHash("sha256").update(verifier).digest("base64url");
  const state = base64url(crypto.randomBytes(32));
  const server = http.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = server.address().port;
  const redirectUri = `http://127.0.0.1:${port}`;
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: GMAIL_SCOPE,
    access_type: "offline",
    prompt: "consent",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
  }).toString();
  console.log("Open this address in a browser on this computer, then sign in to the Gmail account:");
  console.log(url.toString());
  const result = await new Promise((resolve) => {
    const timeout = setTimeout(() => resolve({ error: "Authorization timed out after 10 minutes." }), 10 * 60 * 1000);
    server.on("request", (request, response) => {
      const incoming = new URL(request.url, redirectUri);
      if (!timingSafeEqualText(incoming.searchParams.get("state"), state)) {
        response.writeHead(400, { "content-type": "text/plain; charset=utf-8" }); response.end("Authorization state did not match.");
        clearTimeout(timeout); resolve({ error: "Authorization state did not match." }); return;
      }
      const code = incoming.searchParams.get("code");
      const failure = incoming.searchParams.get("error");
      response.writeHead(code ? 200 : 400, { "content-type": "text/plain; charset=utf-8" });
      response.end(code ? "Gmail authorization completed. You can close this tab and start the adapter." : "Gmail authorization was not completed.");
      clearTimeout(timeout); resolve(code ? { code } : { error: failure || "Authorization was denied." });
    });
  });
  await new Promise((resolve) => server.close(resolve));
  if (result.error) throw new Error(result.error);
  const tokens = await formPost("https://oauth2.googleapis.com/token", {
    client_id: config.clientId,
    ...(typeof config.clientSecret === "string" && config.clientSecret ? { client_secret: config.clientSecret } : {}),
    code: result.code,
    code_verifier: verifier,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });
  if (typeof tokens.refresh_token !== "string" || !tokens.refresh_token || typeof tokens.access_token !== "string") {
    throw new Error("Google did not return a refresh token. Remove the app’s access in Google Account security settings, then authorize again.");
  }
  await writePrivateJson(config.stateFile, { refreshToken: tokens.refresh_token, accessToken: tokens.access_token, expiresAt: Date.now() + Math.max(60, Number(tokens.expires_in || 3600)) * 1000 });
  console.log(`Authorization stored in ${config.stateFile}. This file is mode 0600 and must stay on this computer.`);
}

async function start(config) {
  const key = await fsp.readFile(path.resolve(config.tls.keyPath));
  const cert = await fsp.readFile(path.resolve(config.tls.certPath));
  const permit = requestLimiter();
  const server = https.createServer({ key, cert, minVersion: "TLSv1.2" }, async (request, response) => {
    const remote = peerAddress(request);
    if (!isAllowedClient(remote, config.allowedClientIPs)) { sendJson(response, 403, { error: "client not allowed" }); return; }
    if (request.method === "GET" && request.url === "/health") { sendJson(response, 200, { status: "ready" }); return; }
    const requestUrl = new URL(request.url, "https://adapter.invalid");
    if (request.method !== "GET" || requestUrl.pathname !== "/v1/messages") { sendJson(response, 404, { error: "not found" }); return; }
    const auth = request.headers.authorization || "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!timingSafeEqualText(token, config.adapterToken)) { sendJson(response, 401, { error: "unauthorized" }); return; }
    if (!permit(remote)) { sendJson(response, 429, { error: "manual check rate limit reached" }); return; }
    try {
      const messages = await latestMetadata(config, normaliseLimit(requestUrl.searchParams.get("limit")));
      sendJson(response, 200, { messages });
    } catch (error) {
      console.error(`Gmail metadata request failed: ${error.message}`);
      sendJson(response, 502, { error: "gmail metadata unavailable" });
    }
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(config.listen.port, config.listen.host, resolve); });
  console.log(`Gmail adapter listening over HTTPS on ${config.listen.host}:${config.listen.port}. Only configured Kobo IPs are accepted.`);
}

async function main() {
  const command = process.argv[2];
  if (command === "token") { console.log(base64url(crypto.randomBytes(36))); return; }
  if (command !== "authorize" && command !== "start") { usage(); process.exitCode = 2; return; }
  const config = await loadConfig();
  if (command === "authorize") await authorize(config);
  else await start(config);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(`Adapter failed: ${error.message}`); process.exitCode = 1; });
}

export { GMAIL_SCOPE, MAX_MESSAGES, metadataFromMessage, normaliseLimit, isAllowedClient, timingSafeEqualText };
