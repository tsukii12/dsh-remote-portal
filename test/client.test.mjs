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
  assert.match(src, /yuremote-qr-empty[^\n]*\n[^\n]*status\.lastError && !blockedByPassword \? friendlyGateway\(status\.lastError\) : t\("qrNotRunning"\)/);
});

test("the status poll waits for each answer before asking again", () => {
  // A fixed 3 s setInterval with an 8 s timeout kept up to three /status
  // requests open at once on a slow relay.
  const poll = /\/\/ ── polling:[\s\S]*?\}, \[\]\);/.exec(src);
  assert.ok(poll, "polling effect not found");
  assert.doesNotMatch(poll[0], /setInterval/);
  assert.match(poll[0], /if \(!alive \|\| inFlight\) return;/);
  assert.match(poll[0], /refreshStatus\(\)\.then\(function \(\) \{\s*inFlight = false;\s*if \(alive\) timer = setTimeout\(tick, POLL_MS\);/);
});

test("an older /status answer never replaces a newer one", () => {
  const body = /function refreshStatus\(\) \{([\s\S]*?)\n      \}/.exec(src);
  assert.ok(body, "refreshStatus not found");
  assert.match(body[1], /var seq = \+\+statusSeq\.current\.sent;/);
  assert.match(body[1], /if \(seq <= statusSeq\.current\.applied\) return;/);
  // Status that comes back with an action counts as the newest answer.
  assert.match(src, /if \(seq === undefined\) statusSeq\.current\.applied = \+\+statusSeq\.current\.sent;/);
});

test("a failed poll says the status shown may be out of date", () => {
  assert.match(src, /if \(st\.pollErr\) \{\s*alerts\.push\([^\n]*key: "stale"/);
  assert.match(src, /statusStale: "暂时读不到最新状态/);
  assert.match(src, /statusStale: "Cannot read the latest status/);
});

test("folder-picker and password errors from the host are shown in the panel's language", () => {
  const grab = (name) => {
    const at = src.indexOf(`function ${name}(`);
    let depth = 0;
    for (let i = src.indexOf("{", at); i < src.length; i++) {
      if (src[i] === "{") depth++;
      else if (src[i] === "}" && --depth === 0) return src.slice(at, i + 1);
    }
    throw new Error(name + " not found");
  };
  const dict = (lang) => {
    const block = src.match(new RegExp(`\\n\\s*${lang}:\\s*\\{([\\s\\S]*?)\\n\\s*\\}`))[1];
    return Object.fromEntries([...block.matchAll(/^\s*([A-Za-z0-9_]+):\s*"((?:[^"\\]|\\.)*)"/gm)].map((m) => [m[1], JSON.parse(`"${m[2]}"`)]));
  };
  for (const lang of ["zh", "en"]) {
    const table = dict(lang);
    const t = (key, vars) => Object.entries(vars || {}).reduce((s, [k, v]) => s.split(`{${k}}`).join(String(v)), table[key] ?? key);
    const { pickError, friendlyError } = new Function("t", `${grab("friendlyError")}\n${grab("pickError")}\nreturn { pickError, friendlyError };`)(t);
    const host = (code, error) => pickError({ ok: false, status: 400, data: { ok: false, code, error }, error });
    for (const [code, error] of [
      ["bad-name", "invalid folder name"],
      ["mkdir-failed", "cannot create folder: EACCES"],
      ["not-found", "not found: /nope"],
      ["not-a-directory", "parent is not a directory"],
      ["password-too-long", "password is too long"],
    ]) {
      const shown = host(code, error);
      assert.notEqual(shown, error, `${lang} ${code}: raw host English must not reach the panel`);
      assert.ok(Object.values(table).includes(shown) || shown.includes("EACCES"), `${lang} ${code}: ${shown}`);
      if (lang === "zh") assert.match(shown, /[\u4e00-\u9fff]/, `${code} must read in Chinese: ${shown}`);
    }
    assert.match(host("mkdir-failed", "cannot create folder: EACCES"), /EACCES/, "the system code stays visible");
    assert.equal(friendlyError("password is too long"), table.pwLong);
  }
});
