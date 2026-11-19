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
