/**
 * dsh-remote-portal — response-header hardening tests.
 *
 * The portal is the only surface in the product that hands a stranger on the
 * network an HTML page containing an authentication form, so its responses are
 * pinned here rather than left to review: clickjacking, MIME sniffing, referrer
 * leakage of a one-time pair link, and a permissive CSP are all one header away
 * from being a real vulnerability.
 *
 * The other half of this file is the negative assertion that matters just as
 * much: proxied upstream responses must come through *unmodified*, because the
 * app behind the gate belongs to dsh and rewriting its headers could break it.
 *
 * Run with:  node --test
 */
import { test, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { createGateway } from "../lib/gateway.mjs";

const quiet = { info() {}, warn() {}, error() {} };
const dirs = [];
const cleanups = [];

function tmpDir() {
  const dir = mkdtempSync(join(tmpdir(), "drp-sec-"));
  dirs.push(dir);
  return dir;
}

after(async () => {
  for (const fn of cleanups.splice(0).reverse()) {
    try { await fn(); } catch { /* best effort */ }
  }
  for (const dir of dirs.splice(0)) {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

/** Accept sockets explicitly so `server.close()` cannot hang on an upgraded one. */
async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  const accepted = new Set();
  server.on("connection", (socket) => {
    accepted.add(socket);
    socket.once("close", () => accepted.delete(socket));
  });
  cleanups.push(() => new Promise((resolve) => {
    for (const socket of accepted) {
      try { socket.destroy(); } catch { /* gone */ }
    }
    accepted.clear();
    try { server.closeAllConnections?.(); } catch { /* http only */ }
    try { server.close(() => resolve()); } catch { resolve(); }
  }));
  return server.address().port;
}

function makeCtx(upstreamPort) {
  const ctx = {
    logger: quiet,
    webServer: {
      host: "127.0.0.1",
      protocol: "http:",
      port: upstreamPort,
      getOrigin() { return `http://127.0.0.1:${ctx.webServer.port}`; },
    },
    get() { return undefined; },
  };
  return ctx;
}

/** One request, no redirect following, raw headers out. */
function request(port, path, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    req.on("error", reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

async function startPortal() {
  const upstream = http.createServer((req, res) => {
    if (req.url.startsWith("/?token=")) {
      res.writeHead(303, {
        location: "./",
        "set-cookie": ["dsh-auth-testhost=v1.sig; Path=/; HttpOnly; SameSite=Strict"],
      });
      res.end();
      return;
    }
    // A distinctive marker header proves the response we inspect is the
    // upstream's own, not something the gateway rebuilt.
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "x-upstream-marker": "dsh-app",
      "content-security-policy": "default-src 'self'",
    });
    res.end("<html><body>app</body></html>");
  });
  const upstreamPort = await listen(upstream);

  const gw = createGateway({
    ctx: makeCtx(upstreamPort),
    config: { host: "127.0.0.1", port: 0, auth: { mode: "password", sessionDays: 30, maxFailures: 5, lockSeconds: 60 } },
    stateDir: tmpDir(),
    log: quiet,
    pluginDir: fileURLToPath(new URL("..", import.meta.url)),
    pluginVersion: "9.9.9-test",
  });
  cleanups.push(() => gw.stop());
  await gw.setPassword("correct horse battery");
  await gw.start();
  return { gw, port: gw.status().port };
}

const HARDENED = [
  ["x-frame-options", /^deny$/i],
  ["x-content-type-options", /^nosniff$/i],
  ["referrer-policy", /^no-referrer$/i],
  ["cross-origin-opener-policy", /^same-origin$/i],
  ["cross-origin-resource-policy", /^same-origin$/i],
  ["permissions-policy", /camera=\(\)/],
];

function assertHardened(headers, where) {
  for (const [name, pattern] of HARDENED) {
    assert.ok(headers[name], `${where}: missing ${name}`);
    assert.match(String(headers[name]), pattern, `${where}: ${name}=${headers[name]}`);
  }
  const csp = String(headers["content-security-policy"] || "");
  assert.ok(csp !== "", `${where}: missing content-security-policy`);
  assert.match(csp, /frame-ancestors 'none'/, `${where}: CSP must forbid framing`);
  assert.match(csp, /default-src 'none'/, `${where}: CSP default-src must be 'none'`);
  assert.match(csp, /base-uri 'none'/, `${where}: CSP must pin base-uri`);
  assert.match(csp, /form-action 'self'/, `${where}: CSP must restrict form-action`);
  assert.doesNotMatch(csp, /unsafe-eval/, `${where}: CSP must not allow eval`);
  assert.doesNotMatch(csp, /frame-ancestors \*/, `${where}: CSP must not allow any framer`);
}

// ───────────────────────────────────────────────────────────────────────────

test("the login page carries the full hardening set", async () => {
  const { port } = await startPortal();
  const res = await request(port, "/");
  assert.equal(res.status, 200);
  assert.match(String(res.headers["content-type"]), /text\/html/);
  assert.match(res.body, /<!doctype html>/i, "expected the real login page, not a fallback");
  assertHardened(res.headers, "login page");
  assert.match(String(res.headers["cache-control"]), /no-store/, "login page must never be cached");
});

test("JSON endpoints carry the same set", async () => {
  const { port } = await startPortal();
  for (const path of ["/__portal/health", "/__portal/manifest.webmanifest"]) {
    const res = await request(port, path);
    assert.ok(res.status === 200 || res.status === 404, `${path} -> ${res.status}`);
    assertHardened(res.headers, path);
  }
});

test("the login redirect carries the set and no body", async () => {
  const { port } = await startPortal();
  const res = await request(port, "/__portal/login", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "password=correct horse battery",
  });
  assert.equal(res.status, 303);
  assertHardened(res.headers, "login 303");
  assert.equal(res.body, "");
});

test("an unauthenticated API call is refused with the set", async () => {
  const { port } = await startPortal();
  const res = await request(port, "/api/session");
  assert.equal(res.status, 401);
  assertHardened(res.headers, "401");
});

test("static assets served by the gateway carry the set", async () => {
  const { port } = await startPortal();
  const res = await request(port, "/dsh-remote-portal/assets/mobile.css");
  assert.equal(res.status, 200);
  assert.match(String(res.headers["content-type"]), /text\/css/);
  assertHardened(res.headers, "asset");
});

test("a 404 still carries the set (no bare Node response)", async () => {
  const { port } = await startPortal();
  const res = await request(port, "/dsh-remote-portal/assets/nope.css");
  assert.equal(res.status, 404);
  assertHardened(res.headers, "404");
});

test("proxied responses are passed through unmodified", async () => {
  const { port } = await startPortal();
  const login = await request(port, "/__portal/login", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "password=correct horse battery",
  });
  const cookie = String([].concat(login.headers["set-cookie"] || []).join("; "))
    .split(";")[0];
  const res = await request(port, "/", { headers: { cookie } });
  assert.equal(res.status, 200);
  assert.equal(res.headers["x-upstream-marker"], "dsh-app", "the upstream body must reach the client");
  assert.equal(
    res.headers["content-security-policy"],
    "default-src 'self'",
    "the gateway must not overwrite the app's own CSP",
  );
  assert.equal(res.headers["x-frame-options"], undefined, "the gateway must not add XFO to the app");
});

test("an unusable TLS material set is reported as state, never thrown", async () => {
  const { gw } = await startPortal();
  assert.equal(gw.status().running, true);
  // A path that does not exist is the realistic failure (typo, moved file, a
  // Windows path written with the wrong separators). The panel has to be able to
  // show it, so it must land in status().lastError instead of rejecting.
  const status = await gw.applyConfig({
    tls: { certFile: "C:/definitely/not/here/cert.pem", keyFile: "C:/definitely/not/here/key.pem" },
  });
  assert.equal(status.running, false);
  assert.equal(status.state, "error");
  assert.match(String(status.lastError), /cert|ENOENT|no such|cannot/i);
  // And the portal can come back: clearing TLS restarts it on the same port.
  const back = await gw.applyConfig({ tls: null });
  assert.equal(back.running, true, `expected the listener to restart, got ${JSON.stringify(back.lastError)}`);
  assert.equal(back.protocol, "http:");
});
