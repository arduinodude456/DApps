import assert from "node:assert/strict";
import { GMAIL_SCOPE, MAX_MESSAGES, isAllowedClient, metadataFromMessage, normaliseLimit, timingSafeEqualText } from "./gmail-adapter.mjs";

assert.equal(GMAIL_SCOPE, "https://www.googleapis.com/auth/gmail.metadata");
assert.equal(normaliseLimit("1"), 1);
assert.equal(normaliseLimit("500"), MAX_MESSAGES);
assert.equal(normaliseLimit("invalid"), MAX_MESSAGES);
assert.equal(isAllowedClient("::ffff:192.168.1.42", ["192.168.1.42"]), true);
assert.equal(isAllowedClient("192.168.1.99", ["192.168.1.42"]), false);
assert.equal(timingSafeEqualText("same-token", "same-token"), true);
assert.equal(timingSafeEqualText("same-token", "different-token"), false);
assert.deepEqual(metadataFromMessage({ id: "abc_123", payload: { headers: [{ name: "From", value: "Alice <alice@example.com>" }, { name: "Subject", value: "A subject" }] } }), { id: "abc_123", from: "Alice <alice@example.com>", subject: "A subject" });
assert.equal(metadataFromMessage({ id: "abc_123", payload: { headers: [{ name: "From", value: "Alice" }] } }), null);
assert.equal(metadataFromMessage({ id: "bad id", payload: { headers: [{ name: "From", value: "Alice" }, { name: "Subject", value: "Subject" }] } }), null);
console.log("Gmail local adapter test: OK");
