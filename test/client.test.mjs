import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = readFileSync(new URL("../client.js", import.meta.url), "utf8");

test("the copied pairing link quotes its real remaining time", () => {
  // The code lives 180 s by default (30-900 s allowed); a fixed "5 minutes"
  // sat next to a QR countdown at 0:48.
  const copies = [...src.matchAll(/pairLinkCopied:\s*"([^"]*)"/g)].map((m) => m[1]);
  assert.equal(copies.length, 2, "one string per locale");
  for (const s of copies) {
    assert.match(s, /\{t\}/, `"${s}" must take the remaining time`);
    assert.doesNotMatch(s, /\d\s*(分钟|min)/, `"${s}" must not hard-code a duration`);
  }
  assert.match(src, /t\("pairLinkCopied", \{ t: mmss\(left\) \}\)/);
});

test("gateway errors shown in the panel go through the localized error table", () => {
  // `port 3081 on 0.0.0.0 is already in use` reached a Chinese panel verbatim
  // while errPortBusy had a translation all along.
  const body = /function friendlyGateway\(message\) \{([\s\S]*?)\n    \}/.exec(src);
  assert.ok(body, "friendlyGateway not found");
  assert.match(body[1], /return friendlyError\(text\);\s*$/, "unknown gateway text must fall back to friendlyError");
  assert.match(src, /friendlyError\(text\) \{[\s\S]*?already in use[\s\S]*?errPortBusy/);
});

test("the pairing card names the real reason the portal is not running", () => {
  // With a password set and the port taken, the card still said "set an access
  // password and enable it".
  assert.match(src, /drp-qr-empty[^\n]*\n[^\n]*status\.lastError && !blockedByPassword \? friendlyGateway\(status\.lastError\) : t\("qrNotRunning"\)/);
});
