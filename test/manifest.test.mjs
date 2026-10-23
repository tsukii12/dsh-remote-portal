/**
 * test/manifest.test.mjs — one release number, five places.
 *
 * The version appears in the package manifest, the host half, the browser half, the
 * relay and the deploy script. The deploy script is the one that matters most: it
 * pins the mirror it downloads `relay.mjs` from, so a stale number there fetches an
 * older relay without any other symptom.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (rel) => readFileSync(join(root, rel), "utf8");

const version = JSON.parse(read("package.json")).version;

/** Pull the first capture of `pattern` out of `text`, failing loudly when absent. */
function grab(text, pattern, what) {
  const m = text.match(pattern);
  assert.ok(m, `could not find the version in ${what}`);
  return m[1];
}

test("every copy of the version matches package.json", () => {
  const found = {
    "index.js": grab(read("index.js"), /PLUGIN_VERSION\s*=\s*"([^"]+)"/, "index.js"),
    "client.js": grab(read("client.js"), /CLIENT_VERSION\s*=\s*"([^"]+)"/, "client.js"),
    "lib/tunnel.mjs": grab(read("lib/tunnel.mjs"), /version:\s*"([^"]+)"/, "lib/tunnel.mjs"),
    "tools/relay.mjs": grab(read("tools/relay.mjs"), /RELAY_VERSION\s*=\s*"([^"]+)"/, "tools/relay.mjs"),
    "tools/deploy-relay.sh": grab(read("tools/deploy-relay.sh"), /SELF_VERSION="([^"]+)"/, "tools/deploy-relay.sh"),
  };
  for (const [file, value] of Object.entries(found)) {
    assert.equal(value, version, `${file} says ${value}, package.json says ${version}`);
  }
});

test("the deploy script pins the mirror to its own version", () => {
  const script = read("tools/deploy-relay.sh");
  assert.match(
    script,
    /cdn\.jsdelivr\.net\/gh\/tsukii12\/dsh-remote-portal@v\$\{SELF_VERSION\}/,
    "jsDelivr caches by ref: an unpinned @master there can serve an older relay.mjs",
  );
  assert.equal(
    /cdn\.jsdelivr\.net\/gh\/[^ ]*@master/.test(script),
    false,
    "the jsDelivr candidate must not track master",
  );
});

test("the install mirrors are all reachable-looking URLs", () => {
  const script = read("tools/deploy-relay.sh");
  const block = script.slice(script.indexOf("RAW_BASES="), script.indexOf("if [ ! -f \"$PORTAL_DIR/relay.mjs\" ]"));
  const urls = block.match(/https:\/\/[^ \n\\]+/g) || [];
  assert.ok(urls.length >= 3, `expected at least three mirrors, found ${urls.length}`);
  for (const url of urls) {
    assert.match(url, /^https:\/\/[a-z0-9.-]+(\/[^\s]*)?$/i, `not a plain https URL: ${url}`);
    assert.equal(url.includes("$"), url.includes("${SELF_VERSION}"), `unexpected interpolation in ${url}`);
  }
});
