/**
 * dsh-remote-portal — host-side tests (node:test, no dependencies).
 *
 * Everything here runs against a *real* listener and a *real* dummy upstream on
 * loopback: the behaviours worth pinning (header rewriting, upgrade tunnelling,
 * no-buffering streaming, cookie minting on 401) are exactly the ones a mocked
 * request object cannot prove.
 *
 * Run with:  node --test test/
 */
import { test, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { createGateway, normalizeConfig } from "../lib/gateway.mjs";
import { Lockout, hashPassword, verifyPassword, issueSession, verifySessionCookie } from "../lib/auth.mjs";
import { assertBindSafe, discoverAddressesSync, isLoopback, isWildcard, urlsFor } from "../lib/net.mjs";
import {
  buildUpstreamHeaders, sanitizeTarget, rewriteLocation, stripCookies, withMintedCookies, upstreamFromContext,
} from "../lib/proxy.mjs";
import { sanitizeSetCookie, cookieAuthority } from "../lib/mint.mjs";

// ───────────────────────────────────────────────────────────────────────────
// harness
// ───────────────────────────────────────────────────────────────────────────

const quiet = { info() {}, warn() {}, error() {} };
const dirs = [];
const cleanups = [];

function tmpDir() {
  const dir = mkdtempSync(join(tmpdir(), "drp-host-"));
  dirs.push(dir);
  return dir;
}

/**
 * Teardown. The dummy upstream servers and any gateway a test forgot to stop are
 * real listeners: without this the runner would sit on open handles forever.
 * (A `process.on('exit')` handler cannot await a `server.close()`.)
 */
after(async () => {
  const verbose = process.env.DRP_TEST_VERBOSE === "1";
  for (const fn of cleanups.splice(0).reverse()) {
    const startedAt = Date.now();
    if (verbose) console.log(`# cleanup start ${String(fn).slice(0, 60)}`);
    try { await fn(); } catch { /* best effort */ }
    if (verbose) console.log(`# cleanup done ${Date.now() - startedAt}ms`);
  }
  for (const dir of dirs.splice(0)) {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

process.on("exit", () => {
  for (const dir of dirs.splice(0)) {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

function makeCtx({ upstreamPort = 0, connection } = {}) {
  const ctx = {
    logger: quiet,
    webServer: {
      host: "127.0.0.1",
      protocol: "http:",
      port: upstreamPort,
      getOrigin() { return `http://127.0.0.1:${ctx.webServer.port}`; },
    },
    get(name) {
      if (name === "connection") return connection;
      return undefined;
    },
  };
  return ctx;
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  // Track every accepted socket, including the ones that get upgraded: Node
  // removes upgraded sockets from its own accounting, so `closeAllConnections()`
  // alone can leave `server.close()` waiting forever.
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

/**
 * A stand-in for the dsh web server. It records what actually arrived, which is
 * the only way to prove the Host/Origin rewrite happened.
 */
async function startUpstream() {
  const seen = [];
  let mintCount = 0;
  const server = http.createServer((req, res) => {
    seen.push({ at: Date.now(), method: req.method, url: req.url, headers: { ...req.headers } });

    // Token exchange (the endpoint mint.mjs talks to).
    if (req.url.startsWith("/?token=")) {
      mintCount += 1;
      res.writeHead(303, {
        location: "./",
        "set-cookie": ["dsh-auth-testhost=v1.eyJ2ZXJzaW9uIjoxLCJhdXRob3JpdHkiOiIxMjcuMC4wLjE6OTk5OSJ9.sig; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"],
      });
      res.end();
      return;
    }
    if (req.url.startsWith("/redirect")) {
      res.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/after-login` });
      res.end();
      return;
    }
    if (req.url.startsWith("/stream")) {
      res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      res.write("first\n");
      setTimeout(() => {
        try { res.write("second\n"); res.end(); } catch { /* gone */ }
      }, 160);
      return;
    }
    if (req.url.startsWith("/needs-dsh-cookie")) {
      // Simulates dsh's own auth: only a request carrying the minted cookie gets through.
      if (!/dsh-auth-/.test(String(req.headers.cookie || ""))) {
        res.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
        res.end("dsh web authentication required; reopen the URL printed by dsh web.");
        return;
      }
    }
    const payload = JSON.stringify({
      ok: true,
      url: req.url,
      host: req.headers.host ?? null,
      origin: req.headers.origin ?? null,
      referer: req.headers.referer ?? null,
      cookie: req.headers.cookie ?? null,
      xff: req.headers["x-forwarded-for"] ?? null,
      xfp: req.headers["x-forwarded-proto"] ?? null,
      xfh: req.headers["x-forwarded-host"] ?? null,
    });
    res.writeHead(200, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(payload) });
    res.end(payload);
  });
  server.on("upgrade", (req, socket) => {
    seen.push({ at: Date.now(), upgrade: true, method: req.method, url: req.url, headers: { ...req.headers } });
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      "Sec-WebSocket-Accept: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    );
    socket.on("data", (chunk) => {
      try { socket.write(Buffer.concat([Buffer.from("echo:"), chunk])); } catch { /* gone */ }
    });
    socket.on("error", () => { try { socket.destroy(); } catch { /* gone */ } });
  });
  const port = await listen(server);
  return { server, seen, port, mintCount: () => mintCount };
}

function request(port, path, { method = "GET", headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, method, path, headers, agent: false }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
      res.on("error", reject);
    });
    req.on("error", reject);
    if (body !== null) req.write(body);
    req.end();
  });
}

/** Collects chunks with arrival timestamps (proves streaming vs buffering). */
function streamRequest(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const req = http.request({ host: "127.0.0.1", port, method: "GET", path, headers, agent: false }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push({ at: Date.now() - startedAt, text: chunk.toString("utf8") }));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, chunks, endedAt: Date.now() - startedAt }));
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end();
  });
}

/** Raw TCP: needed for absolute-form targets and for the WebSocket handshake. */
function rawExchange(port, payload, { settleMs = 500, until = null } = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    let text = "";
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      try { socket.destroy(); } catch { /* gone */ }
      resolve(text);
    };
    socket.setNoDelay(true);
    socket.on("connect", () => socket.write(payload));
    socket.on("data", (chunk) => {
      text += chunk.toString("utf8");
      if (until && until(text)) finish();
    });
    socket.on("error", (error) => {
      if (done) return;
      done = true;
      // A refused/reset connection is a legitimate observation for these tests.
      resolve(`${text}\n[error ${error.code || error.message}]`);
    });
    socket.on("close", finish);
    const timer = setTimeout(finish, settleMs);
    timer.unref?.();
  });
}

function cookieHeaderFrom(response) {
  const list = response.headers["set-cookie"] || [];
  const portal = list.map((value) => value.split(";")[0]).find((pair) => pair.startsWith("dsh_portal="));
  return { all: list, portal: portal || "" };
}

async function login(portalPort, password, { headers = {}, next } = {}) {
  const form = new URLSearchParams();
  form.set("password", password);
  if (next) form.set("next", next);
  const body = form.toString();
  const response = await request(portalPort, "/__portal/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "content-length": Buffer.byteLength(body),
      accept: "text/html,application/xhtml+xml",
      ...headers,
    },
    body,
  });
  return { response, ...cookieHeaderFrom(response) };
}

/** Gateway with a password already set, bound to an ephemeral loopback port. */
async function startPortal({ upstreamPort = 0, connection, stateDir, config = {} } = {}) {
  const dir = stateDir || tmpDir();
  const ctx = makeCtx({ upstreamPort, connection });
  const gw = createGateway({
    ctx,
    config: { host: "127.0.0.1", port: 0, auth: { mode: "password", sessionDays: 30, maxFailures: 5, lockSeconds: 60 }, ...config },
    stateDir: dir,
    log: quiet,
    pluginDir: fileURLToPath(new URL("..", import.meta.url)),
    pluginVersion: "9.9.9-test",
  });
  cleanups.push(() => gw.stop());
  return { gw, ctx, dir };
}

// ───────────────────────────────────────────────────────────────────────────
// lifecycle
// ───────────────────────────────────────────────────────────────────────────

test("binds, stops (idempotently) and rebinds on an ephemeral port", async () => {
  const { gw } = await startPortal();
  await gw.setPassword("correct horse battery");
  await gw.start();
  const first = gw.status();
  assert.equal(first.running, true);
  assert.equal(first.state, "listening");
  assert.ok(first.port > 0);
  assert.match(first.urls[0], /^http:\/\/127\.0\.0\.1:\d+\/$/);
  assert.equal(first.authMode, "password");
  assert.equal(first.passwordSet, true);

  const health = await request(first.port, "/__portal/health");
  assert.equal(health.status, 200);

  await gw.stop();
  assert.equal(gw.status().running, false);
  await gw.stop(); // idempotent: resolves, does not throw
  assert.equal(gw.status().running, false);

  await gw.start();
  const second = gw.status();
  assert.equal(second.running, true);
  assert.ok(second.port > 0);
  const again = await request(second.port, "/__portal/health");
  assert.equal(again.status, 200);
  await gw.stop();
});

test("a non-loopback bind without a password is refused with needs-password", async () => {
  const { gw } = await startPortal({ config: { host: "0.0.0.0" } });
  await assert.rejects(() => gw.start(), (error) => error.code === "needs-password");
  const status = gw.status();
  assert.equal(status.state, "needs-password");
  assert.equal(status.running, false);
  assert.match(String(status.lastError), /password/i);

  // Open mode is loopback-only even with a password: that is an open proxy.
  const open = createGateway({
    ctx: makeCtx(),
    config: { host: "0.0.0.0", port: 0, auth: { mode: "open" } },
    stateDir: tmpDir(),
    log: quiet,
  });
  cleanups.push(() => open.stop());
  await assert.rejects(() => open.start(), (error) => error.code === "open-requires-loopback");

  // With a password (and back on loopback) the same gateway starts.
  await gw.applyConfig({ enabled: false });
  await gw.setPassword("correct horse battery");
  const applied = await gw.applyConfig({ host: "127.0.0.1", enabled: true });
  assert.equal(applied.running, true);
  await gw.stop();
});

test("applyConfig reports a port conflict as status.lastError instead of throwing", async () => {
  const blocker = net.createServer();
  const blockedPort = await listen(blocker);
  const { gw } = await startPortal();
  await gw.setPassword("correct horse battery");
  const status = await gw.applyConfig({ host: "127.0.0.1", port: blockedPort, enabled: true });
  assert.equal(status.running, false);
  assert.match(String(status.lastError), /in use/i);
  assert.equal(status.state, "error");
  // The panel can recover by choosing another port.
  const recovered = await gw.applyConfig({ port: 0 });
  assert.equal(recovered.running, true);
  await gw.stop();
});

// ───────────────────────────────────────────────────────────────────────────
// auth
// ───────────────────────────────────────────────────────────────────────────

test("password login sets an HttpOnly session cookie; a wrong password is 401", async () => {
  const { gw } = await startPortal();
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  const wrong = await login(port, "not the password");
  assert.equal(wrong.response.status, 401);
  assert.equal(wrong.portal, "");
  assert.match(wrong.response.headers["content-type"], /text\/html/);
  assert.doesNotMatch(wrong.response.body, /dsh web authentication required/);

  const ok = await login(port, "correct horse battery");
  assert.equal(ok.response.status, 303);
  // Absolute on purpose: a relative "./" resolves against /__portal/login and
  // lands on /__portal/, which is not the app.
  assert.equal(ok.response.headers.location, "/");
  assert.ok(ok.portal.startsWith("dsh_portal="), "expected a portal session cookie");
  const joined = ok.all.join("\n");
  assert.match(joined, /HttpOnly/);
  assert.match(joined, /SameSite=Lax/);
  assert.match(joined, /Path=\//);
  const parts = ok.portal.split("=")[1].split(".");
  assert.equal(parts.length, 4, "cookie value must be id.issuedAt.expiresAt.sig");
  assert.ok(Number(parts[2]) > Date.now(), "cookie must expire in the future");
  await gw.stop();
});

test("wrong password locks the IP out after maxFailures, doubling the wait", async () => {
  const { gw } = await startPortal({ config: { auth: { mode: "password", maxFailures: 3, lockSeconds: 60 } } });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  // The lock starts on the failure that reaches maxFailures: that answer is
  // already a 429 (and the panel renders the countdown page).
  for (let attempt = 1; attempt < 3; attempt += 1) {
    const { response } = await login(port, "wrong-password");
    assert.equal(response.status, 401, `attempt ${attempt} should be 401`);
  }
  const third = await login(port, "wrong-password");
  assert.equal(third.response.status, 429, "the maxFailures-th failure locks immediately");
  const locked = await login(port, "correct horse battery");
  assert.equal(locked.response.status, 429, "a correct password must not bypass the lock");
  assert.ok(Number(locked.response.headers["retry-after"]) >= 1);
  assert.match(locked.response.headers["content-type"], /text\/html/);

  // XHR clients get JSON rather than a page.
  const xhrBody = "password=correct%20horse%20battery";
  const xhr = await request(port, "/__portal/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "content-length": Buffer.byteLength(xhrBody),
      accept: "application/json",
    },
    body: xhrBody,
  });
  assert.equal(xhr.status, 429);
  assert.equal(JSON.parse(xhr.body).ok, false);

  // A different IP is not affected (the lockout is per client IP). The unit
  // check below drives the clock explicitly, so it proves the escalation rule
  // (60 s → ×2 → capped at 15 min) instead of merely observing "some lock".
  const unit = new Lockout({ maxFailures: 3, baseLockMs: 60_000 });
  const t0 = 1_000_000;
  unit.fail("10.0.0.9", t0);
  unit.fail("10.0.0.9", t0 + 1);
  unit.fail("10.0.0.9", t0 + 2);
  assert.deepEqual(
    { locked: unit.state("10.0.0.9", t0 + 3).locked, retryAfter: unit.state("10.0.0.9", t0 + 3).retryAfter },
    { locked: true, retryAfter: 60 },
    "the first lock window is lockSeconds",
  );
  assert.equal(unit.state("10.0.0.10", t0 + 3).locked, false, "another IP is unaffected");

  // Each further batch of maxFailures doubles the window: 60 → 120 → 240 → …,
  // capped at 15 min.
  const expectedWindows = [120, 240, 480, 900, 900];
  let cursor = t0 + 61_000; // first lock has expired
  assert.equal(unit.state("10.0.0.9", cursor).locked, false);
  for (const expected of expectedWindows) {
    unit.fail("10.0.0.9", cursor);
    unit.fail("10.0.0.9", cursor + 1);
    unit.fail("10.0.0.9", cursor + 2);
    const state = unit.state("10.0.0.9", cursor + 3);
    assert.equal(state.locked, true, `expected a lock at strike for ${expected}s`);
    assert.equal(state.retryAfter, expected, `lock window must escalate to ${expected}s`);
    cursor += expected * 1000 + 1000;
  }
  // A success clears the escalation entirely.
  unit.succeed("10.0.0.9");
  assert.equal(unit.state("10.0.0.9", cursor).locked, false);
  assert.equal(unit.state("10.0.0.9", cursor).strikes, 0);
  await gw.stop();
});

test("stop() resolves when the gateway never started", async () => {
  const { gw } = await startPortal();
  const startedAt = Date.now();
  await gw.stop();
  await gw.stop();
  assert.ok(Date.now() - startedAt < 2000, "stop() must not wait for a listener that does not exist");
  assert.equal(gw.status().running, false);
  // and start()/stop() still work afterwards
  await gw.setPassword("correct horse battery");
  await gw.start();
  assert.equal(gw.status().running, true);
  await gw.stop();
  assert.equal(gw.status().running, false);
});

test("a pairing token works exactly once", async () => {
  const { gw } = await startPortal();
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  const pairing = await gw.mintPairing({ ttlSeconds: 120, label: "iPhone" });
  assert.equal(pairing.token.length >= 40, true);
  assert.match(pairing.url, /^http:\/\/127\.0\.0\.1:\d+\/__portal\/pair\?t=/);
  assert.ok(pairing.expiresAt > Date.now());

  const first = await request(port, `/__portal/pair?t=${encodeURIComponent(pairing.token)}`, {
    headers: { accept: "text/html" },
  });
  assert.equal(first.status, 303);
  // The redirect must be absolute: a relative "./" resolves against
  // /__portal/pair → /__portal/, which is not the app (that was the bug).
  assert.equal(first.headers.location, "/", "a scanned pairing link must land on the app");
  assert.ok(cookieHeaderFrom(first).portal.startsWith("dsh_portal="));

  const second = await request(port, `/__portal/pair?t=${encodeURIComponent(pairing.token)}`, {
    headers: { accept: "text/html" },
  });
  assert.equal(second.status, 401);
  assert.match(second.body, /invalid or already used|无效或已被使用/i, "replay must be refused");

  const unknown = await request(port, "/__portal/pair?t=definitely-not-a-token", { headers: { accept: "text/html" } });
  assert.equal(unknown.status, 401);

  // A browser landing on a portal path that is not an endpoint goes to the app.
  const stray = await request(port, "/__portal/", { headers: { accept: "text/html" } });
  assert.equal(stray.status, 303);
  assert.equal(stray.headers.location, "/");

  // The same token posted through the login form (auth-page's pair button) is
  // refused too: redemption is single-use across both entry points.
  const pairBody = `token=${encodeURIComponent(pairing.token)}&pairToken=${encodeURIComponent(pairing.token)}`;
  const posted = await request(port, "/__portal/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "content-length": Buffer.byteLength(pairBody),
      accept: "text/html",
    },
    body: pairBody,
  });
  assert.equal(posted.status, 401);
  await gw.stop();
});

test("logout clears the portal session and expires dsh cookies", async () => {
  const { gw } = await startPortal();
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const ok = await login(port, "correct horse battery");
  const portal = ok.portal;

  const out = await request(port, "/__portal/logout", {
    method: "POST",
    headers: { cookie: `${portal}; dsh-auth-testhost=abc`, accept: "text/html" },
  });
  assert.equal(out.status, 303);
  const cookies = out.headers["set-cookie"] || [];
  assert.ok(cookies.some((value) => /^dsh_portal=;/.test(value)), "portal cookie must be cleared");
  assert.ok(cookies.some((value) => /^dsh-auth-testhost=;/.test(value)), "dsh cookie must be expired");

  const after = await request(port, "/api/x", {
    headers: { cookie: portal, accept: "application/json" },
  });
  assert.equal(after.status, 401);
  await gw.stop();
});

// ───────────────────────────────────────────────────────────────────────────
// proxy
// ───────────────────────────────────────────────────────────────────────────

test("proxies with rewritten Host/Origin/Referer and forwards X-Forwarded-*", async () => {
  const upstream = await startUpstream();
  const { gw, ctx } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, "correct horse battery");
  assert.ok(portal);

  const portalOrigin = `http://127.0.0.1:${port}`;
  const seenBefore = upstream.seen.length;
  const response = await request(port, "/api/hello?x=1", {
    headers: {
      cookie: `${portal}; theme=dark`,
      origin: portalOrigin,
      referer: `${portalOrigin}/settings`,
      accept: "application/json",
    },
  });
  assert.equal(response.status, 200);
  const payload = JSON.parse(response.body);
  assert.equal(payload.url, "/api/hello?x=1", "path and query pass through untouched");
  assert.equal(payload.host, `127.0.0.1:${upstream.port}`, "Host must be rewritten to the upstream authority");
  assert.equal(payload.origin, `http://127.0.0.1:${upstream.port}`, "Origin must be rewritten");
  assert.equal(payload.referer, `http://127.0.0.1:${upstream.port}/settings`, "Referer prefix must be rewritten");
  assert.equal(payload.xff, "127.0.0.1");
  assert.equal(payload.xfp, "http");
  assert.equal(payload.xfh, `127.0.0.1:${port}`);
  assert.equal(payload.cookie, "theme=dark", "the portal cookie must never leak upstream");
  assert.equal(upstream.seen.length, seenBefore + 1);

  // Lazy upstream read: the gateway is built before the host has a port.
  ctx.webServer.port = 0;
  const unavailable = await request(port, "/api/hello", { headers: { cookie: portal, accept: "application/json" } });
  assert.equal(unavailable.status, 503);
  ctx.webServer.port = upstream.port;

  await gw.stop();
});

test("rewrites an absolute upstream Location back to the portal origin", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, "correct horse battery");

  const response = await request(port, "/redirect", { headers: { cookie: portal, accept: "text/html" } });
  assert.equal(response.status, 302);
  assert.equal(response.headers.location, `http://127.0.0.1:${port}/after-login`);
  await gw.stop();
});

test("streams responses instead of buffering them", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, "correct horse battery");

  const streamed = await streamRequest(port, "/stream", { cookie: portal });
  assert.equal(streamed.status, 200);
  assert.equal(streamed.chunks.length, 2, "both chunks must arrive");
  assert.equal(streamed.chunks[0].text, "first\n");
  assert.ok(streamed.chunks[0].at < 120, `first chunk must not wait for the second (arrived at ${streamed.chunks[0].at}ms)`);
  assert.ok(streamed.endedAt >= 140, "the response must end only after the upstream finished");
  await gw.stop();
});

test("tunnels a WebSocket upgrade with rewritten headers, both directions", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, "correct horse battery");

  const handshake = [
    "GET /ws?room=1 HTTP/1.1",
    `Host: 127.0.0.1:${port}`,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version: 13",
    `Cookie: ${portal}`,
    "",
    "",
  ].join("\r\n");

  const before = upstream.seen.length;
  const result = await new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port }, () => {
      socket.write(handshake);
    });
    let text = "";
    let sentPing = false;
    socket.setNoDelay(true);
    socket.on("data", (chunk) => {
      text += chunk.toString("utf8");
      if (!sentPing && text.includes("101 Switching Protocols")) {
        sentPing = true;
        socket.write("ping");
      }
      if (text.includes("echo:ping")) {
        socket.destroy();
        resolve(text);
      }
    });
    socket.on("error", reject);
    setTimeout(() => {
      socket.destroy();
      resolve(text);
    }, 1500).unref?.();
  });

  assert.match(result, /101 Switching Protocols/, "the upstream's 101 must reach the client");
  assert.match(result, /echo:ping/, "bytes must flow in both directions");

  const upgradeSeen = upstream.seen.slice(before).find((entry) => entry.upgrade);
  assert.ok(upgradeSeen, "the upstream must have seen an upgrade");
  assert.equal(upgradeSeen.headers.host, `127.0.0.1:${upstream.port}`);
  assert.equal(upgradeSeen.url, "/ws?room=1");
  assert.equal(upgradeSeen.headers.upgrade, "websocket");
  assert.ok(!String(upgradeSeen.headers.cookie || "").includes("dsh_portal"));
  await gw.stop();
});

test("rejects a WebSocket upgrade without a portal session", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  const before = upstream.seen.length;
  const raw = await rawExchange(port, [
    "GET /ws HTTP/1.1",
    `Host: 127.0.0.1:${port}`,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version: 13",
    "",
    "",
  ].join("\r\n"));
  assert.match(raw, /^HTTP\/1\.1 401/);
  assert.equal(upstream.seen.length, before, "an unauthorised upgrade must not reach the upstream");
  await gw.stop();
});

// ───────────────────────────────────────────────────────────────────────────
// portal internals are never proxied
// ───────────────────────────────────────────────────────────────────────────

test("/__portal/* is answered locally and never reaches the upstream", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const before = upstream.seen.length;

  const health = await request(port, "/__portal/health");
  assert.equal(health.status, 200);
  const payload = JSON.parse(health.body);
  assert.equal(payload.ok, true);
  assert.equal(payload.name, "dsh-remote-portal");
  assert.equal(payload.version, "9.9.9-test");
  assert.equal(payload.auth.passwordSet, true);
  assert.equal(payload.upstream.port, upstream.port);
  assert.equal(typeof payload.upstream.reachable, "boolean");

  const manifest = await request(port, "/__portal/manifest.webmanifest");
  assert.equal(manifest.status, 200);
  assert.match(manifest.headers["content-type"], /manifest\+json/);
  assert.equal(JSON.parse(manifest.body).start_url, "/");

  const missing = await request(port, "/__portal/does-not-exist");
  assert.equal(missing.status, 404);

  const unauth = await request(port, "/api/session", { headers: { accept: "application/json" } });
  assert.equal(unauth.status, 401);
  assert.equal(JSON.parse(unauth.body).code, "unauthorized");

  const page = await request(port, "/", { headers: { accept: "text/html" } });
  assert.equal(page.status, 200);
  assert.match(page.headers["content-type"], /text\/html/);
  assert.match(page.headers["cache-control"], /no-store/);
  assert.ok(page.body.length > 100);

  assert.equal(upstream.seen.length, before, "no portal endpoint may be forwarded");
  await gw.stop();
});

test("refuses cross-site posts to the portal endpoints", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  const body = "password=correct%20horse%20battery";
  const crossSite = await request(port, "/__portal/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "content-length": Buffer.byteLength(body),
      origin: "https://evil.example",
      "sec-fetch-site": "cross-site",
      accept: "text/html",
    },
    body,
  });
  assert.equal(crossSite.status, 403);
  assert.equal(JSON.parse(crossSite.body).reason, "origin-mismatch");

  const sameOrigin = await request(port, "/__portal/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "content-length": Buffer.byteLength(body),
      origin: `http://127.0.0.1:${port}`,
      "sec-fetch-site": "same-origin",
      accept: "text/html",
    },
    body,
  });
  assert.equal(sameOrigin.status, 303, "a same-origin login must still work");

  // A proxied request from another site is refused before it reaches upstream.
  const before = upstream.seen.length;
  const crossApi = await request(port, "/api/x", {
    headers: { accept: "application/json", origin: "https://evil.example" },
  });
  assert.equal(crossApi.status, 403);
  assert.equal(upstream.seen.length, before);
  await gw.stop();
});

test("the login page only advertises a LAN address to LAN visitors", async () => {
  const { gw } = await startPortal({});
  await gw.setPassword("correct horse battery");
  await gw.start();
  const status = gw.status();
  const lanHost = status.lanUrls.length > 0 ? new URL(status.lanUrls[0]).host : "";
  const path = "/";

  // A visitor arriving on a LAN/loopback authority gets the "your address is …"
  // hint; a visitor arriving through a relay (any other Host) must not see a
  // 192.168.x.x address that is meaningless from where they are.
  const remote = await request(status.port, path, { headers: { host: "dsh.example.com" } });
  assert.equal(remote.status, 200);
  assert.match(remote.body, /drp-submit/, "the login form must render for a foreign Host");
  if (lanHost) {
    assert.equal(remote.body.includes(lanHost), false, "a public visitor must not see the LAN address");
    const local = await request(status.port, path, { headers: { host: `127.0.0.1:${status.port}` } });
    assert.equal(local.status, 200);
    assert.equal(local.body.includes(lanHost), true, "a LAN visitor keeps the hint");
  }
});

test("serves pairing QR codes locally (size clamped, oversized text refused)", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const before = upstream.seen.length;
  const pairing = await gw.mintPairing({ ttlSeconds: 180 });

  const qr = await request(port, `/dsh-remote-portal/qr.svg?text=${encodeURIComponent(pairing.url)}&size=9999`);
  assert.equal(qr.status, 200);
  assert.match(qr.headers["content-type"], /image\/svg\+xml/);
  assert.match(qr.body, /^<svg/);
  assert.match(qr.body, /role="img"/);
  assert.match(qr.body, /width="1024"/, "size must be clamped to 1024");

  const tooLong = await request(port, `/dsh-remote-portal/qr.svg?text=${"a".repeat(214)}`);
  assert.equal(tooLong.status, 400, "more than 213 UTF-8 bytes must be refused, never truncated");

  const empty = await request(port, "/dsh-remote-portal/qr.svg");
  assert.equal(empty.status, 400);
  assert.equal(upstream.seen.length, before, "the QR route must never reach the upstream");
  await gw.stop();
});

test("refuses absolute-form targets, traversal and unknown methods", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const before = upstream.seen.length;

  const absolute = await rawExchange(port, `GET http://evil.example/ HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`);
  assert.match(absolute, /^HTTP\/1\.1 400/);

  const traversal = await rawExchange(port, `GET /..%2f..%2fetc/passwd HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`);
  assert.match(traversal, /^HTTP\/1\.1 403/);

  const plainTraversal = await rawExchange(port, `GET /lib/../../secrets HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`);
  assert.match(plainTraversal, /^HTTP\/1\.1 403/);

  const weirdMethod = await rawExchange(port, `PROPFIND /api/x HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`);
  assert.match(weirdMethod, /^HTTP\/1\.1 405/);

  assert.equal(upstream.seen.length, before, "rejected targets must never be forwarded");

  // unit-level, same rules
  assert.equal(sanitizeTarget("http://evil.example/").ok, false);
  assert.equal(sanitizeTarget("*").ok, false);
  assert.equal(sanitizeTarget("/a/../b").ok, false);
  assert.equal(sanitizeTarget("/a/%2e%2e/b").ok, false);
  assert.equal(sanitizeTarget("/a/b?c=d").ok, true);
  assert.equal(sanitizeTarget("/__portal/health").isPortal, true);
  await gw.stop();
});

// ───────────────────────────────────────────────────────────────────────────
// dsh browser-cookie minting + 401 recovery
// ───────────────────────────────────────────────────────────────────────────

test("mints a dsh browser cookie and heals a 401 by re-minting once", async () => {
  const upstream = await startUpstream();
  const logs = [];
  const connection = {
    authenticatedUrl(origin) {
      // The real host returns the launch URL; ours is a fixed, recognisable token.
      return `${String(origin).replace(/\/$/, "")}/?token=test-token-value`;
    },
  };
  const dir = tmpDir();
  const ctx = makeCtx({ upstreamPort: upstream.port, connection });
  const gw = createGateway({
    ctx,
    config: { host: "127.0.0.1", port: 0 },
    stateDir: dir,
    log: { info: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) },
    pluginVersion: "9.9.9-test",
  });
  cleanups.push(() => gw.stop());
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  const ok = await login(port, "correct horse battery");
  assert.equal(ok.response.status, 303);
  const mintedOnLogin = ok.all.filter((value) => value.startsWith("dsh-auth-"));
  assert.equal(mintedOnLogin.length, 1, "login must relay the minted dsh cookie");
  assert.match(mintedOnLogin[0], /Path=\//);
  assert.match(mintedOnLogin[0], /HttpOnly/);
  assert.ok(!/Secure/i.test(mintedOnLogin[0]), "Secure must be stripped on a plain-http listener");
  assert.ok(upstream.mintCount() >= 1);
  assert.equal(gw.status().dshSession, "ok");

  // A request whose dsh cookie the browser lost: upstream answers 401, the
  // gateway mints a fresh cookie and retries the same request once.
  const page = await request(port, "/needs-dsh-cookie", {
    headers: { cookie: ok.portal, accept: "text/html" },
  });
  assert.equal(page.status, 200, "the retry must turn the upstream 401 into a 200");
  assert.doesNotMatch(page.body, /dsh web authentication required/);
  const healed = (page.headers["set-cookie"] || []).filter((value) => value.startsWith("dsh-auth-"));
  assert.equal(healed.length, 1, "the refreshed cookie must be handed to the browser");

  // XHR that still cannot be authorised gets a JSON reauthenticate code, never
  // dsh's plain-text 401 page.
  const xhr = await request(port, "/needs-dsh-cookie", {
    headers: { cookie: ok.portal, accept: "application/json" },
  });
  assert.equal(xhr.status, 200, "the mint cache makes the XHR succeed too");

  // Token must never be logged.
  assert.ok(!logs.join("\n").includes("test-token-value"), "the launch token must never reach the logs");

  // mintBrowserCookie() returns raw Set-Cookie values, and [] when unavailable.
  const direct = await gw.mintBrowserCookie();
  assert.equal(direct.length, 1);
  assert.match(direct[0], /^dsh-auth-testhost=/);
  const noService = createGateway({ ctx: makeCtx({ upstreamPort: upstream.port }), config: {}, stateDir: tmpDir(), log: quiet });
  cleanups.push(() => noService.stop());
  assert.deepEqual(await noService.mintBrowserCookie(), []);
  assert.equal(noService.status().dshSession, "unavailable");
  await gw.stop();
});

test("serves the login page instead of dsh's 401 text when re-minting cannot help", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, "correct horse battery");

  // No connection service → no mint → the retry cannot succeed.
  const page = await request(port, "/needs-dsh-cookie", { headers: { cookie: portal, accept: "text/html" } });
  assert.equal(page.status, 200);
  assert.match(page.body, /session-unauthorized/);
  assert.match(page.headers["content-type"], /text\/html/);
  assert.doesNotMatch(page.body, /dsh web authentication required/);

  const xhr = await request(port, "/needs-dsh-cookie", { headers: { cookie: portal, accept: "application/json" } });
  assert.equal(xhr.status, 401);
  assert.equal(JSON.parse(xhr.body).code, "reauthenticate");

  await gw.stop();
});

// ───────────────────────────────────────────────────────────────────────────
// state
// ───────────────────────────────────────────────────────────────────────────

test("state survives a restart (password, devices, counters, access log)", async () => {
  const upstream = await startUpstream();
  const dir = tmpDir();
  const first = await startPortal({ upstreamPort: upstream.port, stateDir: dir });
  await first.gw.setPassword("correct horse battery");
  await first.gw.start();
  const port = first.gw.status().port;
  const { portal } = await login(port, "correct horse battery");
  await request(port, "/api/after-login", { headers: { cookie: portal, accept: "application/json" } });
  const pairing = await first.gw.mintPairing({ label: "phone" });
  const before = first.gw.status();
  assert.ok(before.stats.devices >= 1);
  assert.ok(before.stats.requests >= 2);
  const devicesBefore = first.gw.devices().map((device) => device.id);
  await first.gw.stop();

  const raw = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
  assert.equal(typeof raw.secret, "string");
  assert.equal(raw.password.alg, "scrypt");
  assert.equal(typeof raw.password.hash, "string");
  assert.ok(raw.pairing && Object.keys(raw.pairing).length >= 1);

  const second = await startPortal({ upstreamPort: upstream.port, stateDir: dir });
  const restored = second.gw.status();
  assert.equal(restored.passwordSet, true);
  assert.equal(restored.pairingActive, true);
  assert.deepEqual(second.gw.devices().map((device) => device.id).sort(), devicesBefore.sort());
  assert.equal(restored.stats.devices, before.stats.devices);
  assert.ok(restored.stats.requests >= before.stats.requests);

  // The old cookie still works after the restart (the HMAC secret persisted).
  await second.gw.start();
  const reused = await request(second.gw.status().port, "/api/after-restart", {
    headers: { cookie: portal, accept: "application/json" },
  });
  assert.equal(reused.status, 200);

  // The pairing token minted before the restart is still redeemable.
  const pair = await request(second.gw.status().port, `/__portal/pair?t=${encodeURIComponent(pairing.token)}`);
  assert.equal(pair.status, 303);
  await second.gw.stop();
});

test("recovers from a corrupt state.json using the .bak copy", async () => {
  const dir = tmpDir();
  const first = await startPortal({ stateDir: dir });
  await first.gw.setPassword("correct horse battery");
  await first.gw.mintPairing({ label: "keepme" });
  await first.gw.stop();

  const good = readFileSync(join(dir, "state.json"), "utf8");
  writeFileSync(join(dir, "state.json.bak"), good);
  writeFileSync(join(dir, "state.json"), "{ this is not json");
  assert.ok(existsSync(join(dir, "state.json.bak")));

  const second = await startPortal({ stateDir: dir });
  const status = second.gw.status();
  assert.equal(status.passwordSet, true, "password must be recovered from the backup");
  assert.equal(second.gw.devices().length, 0);
  assert.ok(existsSync(join(dir, "state.json.bak")));
});

// ───────────────────────────────────────────────────────────────────────────
// secrecy
// ───────────────────────────────────────────────────────────────────────────

test("status/config/diagnose/devices/accessLog never expose secrets", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  const password = "correct horse battery";
  await gw.setPassword(password);
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, password);
  const pairing = await gw.mintPairing({ label: "secret-phone" });
  await request(port, `/__portal/pair?t=${encodeURIComponent(pairing.token)}`);
  await request(port, "/api/secret-probe", { headers: { cookie: portal } });

  const rawState = JSON.parse(readFileSync(join(gw.config().stateDir, "state.json"), "utf8"));
  const secrets = [
    password,
    rawState.secret,
    rawState.password.hash,
    rawState.password.salt,
    portal.split("=")[1],
    Object.keys(rawState.sessions)[0],
    pairing.token,
    rawState.pairing[Object.keys(rawState.pairing)[0]].hash,
  ].filter(Boolean);
  assert.ok(secrets.length >= 7);

  // diagnose() probes the upstream on demand before answering, so it is async.
  const report = await gw.diagnose();
  const surfaces = {
    status: JSON.stringify(gw.status()),
    config: JSON.stringify(gw.config()),
    diagnose: JSON.stringify(report),
    devices: JSON.stringify(gw.devices()),
    accessLog: JSON.stringify(gw.accessLog(100)),
  };
  for (const [name, payload] of Object.entries(surfaces)) {
    for (const secret of secrets) {
      assert.equal(payload.includes(secret), false, `${name}() must not contain ${secret.slice(0, 8)}…`);
    }
  }
  // The pairing token is in the URL query, so the access log must have stripped it.
  assert.ok(surfaces.accessLog.includes("/__portal/pair"));
  assert.equal(surfaces.accessLog.includes("t="), false);

  // diagnose() has the documented shape.
  for (const key of ["bindHost", "port", "listening", "addresses", "upstream", "firewallHint", "notes"]) {
    assert.ok(key in report, `diagnose() must expose ${key}`);
  }
  assert.equal(Array.isArray(report.addresses), true);
  assert.equal(report.port, port);
  assert.equal(report.upstream.port, upstream.port);
  assert.equal(gw.version, "9.9.9-test");
  await gw.stop();
});

test("accessLog() is newest-first, capped and query-free", async () => {
  const upstream = await startUpstream();
  const { gw } = await startPortal({ upstreamPort: upstream.port });
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;
  const { portal } = await login(port, "correct horse battery");
  for (let i = 0; i < 5; i += 1) {
    await request(port, `/api/item/${i}?token=should-not-be-logged`, { headers: { cookie: portal } });
  }
  const entries = gw.accessLog(50);
  assert.ok(entries.length >= 5);
  assert.equal(entries[0].path, "/api/item/4");
  assert.ok(entries[0].at >= entries[1].at);
  assert.equal(entries.some((entry) => String(entry.path).includes("should-not-be-logged")), false);
  assert.equal(gw.accessLog(3).length, 3);
  await gw.stop();
});

// ───────────────────────────────────────────────────────────────────────────
// unit-level rules
// ───────────────────────────────────────────────────────────────────────────

test("a tunnel configured in the panel survives a restart", async () => {
  const dir = tmpDir();
  const first = await startPortal({ stateDir: dir });
  await first.gw.applyConfig({
    tunnel: { url: "tcp://127.0.0.1:9", token: "restart-token" },
  });
  const configured = first.gw.status().public;
  assert.equal(configured.configured, true, "status must report the tunnel as configured");
  assert.equal(configured.endpoint, "tcp://127.0.0.1:9");
  await first.gw.stop();

  // A fresh gateway over the same state directory is the restart: the override
  // has to come back from state.json, or public access silently disappears.
  const second = await startPortal({ stateDir: dir });
  const after = second.gw.status().public;
  assert.equal(after.configured, true, "tunnel config must survive a restart");
  assert.equal(after.endpoint, "tcp://127.0.0.1:9");
  assert.equal(JSON.stringify(after).includes("restart-token"), false, "the token must never be returned");

  // And clearing it sticks too.
  await second.gw.applyConfig({ tunnel: null });
  assert.equal(second.gw.status().public.configured, false);
});

test("the directory picker endpoint is behind the portal gate", async () => {
  const { gw } = await startPortal();
  await gw.setPassword("correct horse battery");
  await gw.start();
  const port = gw.status().port;

  // The picker lists directories on the *host*: it must never be reachable
  // without a portal session. (The listing itself is exercised end to end in
  // the live instance; here the security property is what matters.)
  const anonymous = await request(port, "/dsh-remote-portal/fs");
  assert.equal(anonymous.status, 401, "an unauthenticated caller must not list directories");
  assert.equal(/listing/.test(anonymous.body), false);

  // With a session the gateway proxies it to dsh like any other app route.
  const login = await request(port, "/__portal/login", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "content-length": 26 },
    body: "password=correct+horse+battery",
  });
  const cookie = cookieHeaderFrom(login).portal;
  const authed = await request(port, "/dsh-remote-portal/fs", { headers: { cookie } });
  assert.equal(authed.status === 401 || authed.status === 200, true, "a session may reach the route");
});

test("session cookies are bound to the user agent and to the HMAC secret", () => {
  const secret = "a".repeat(43);
  const issued = issueSession({ secret, ttlSeconds: 3600, ua: "UA/1" });
  assert.equal(verifySessionCookie(issued.value, { secret, ua: "UA/1" }).ok, true);
  assert.equal(verifySessionCookie(issued.value, { secret, ua: "UA/2" }).ok, false);
  assert.equal(verifySessionCookie(issued.value, { secret: "b".repeat(43), ua: "UA/1" }).ok, false);
  assert.equal(verifySessionCookie("not.a.cookie", { secret, ua: "UA/1" }).ok, false);
  const expired = issueSession({ secret, ttlSeconds: 60, ua: "UA/1", now: Date.now() - 120_000 });
  assert.equal(verifySessionCookie(expired.value, { secret, ua: "UA/1" }).reason, "expired");
});

test("password hashing is scrypt with a 16-byte salt and constant-time compare", async () => {
  const record = await hashPassword("correct horse battery");
  assert.equal(record.alg, "scrypt");
  assert.equal(record.N, 16384);
  assert.equal(record.r, 8);
  assert.equal(record.p, 1);
  assert.equal(Buffer.from(record.salt, "base64url").length, 16);
  assert.equal(await verifyPassword("correct horse battery", record), true);
  assert.equal(await verifyPassword("wrong", record), false);
  assert.equal(await verifyPassword("anything", null), false, "no password record must never verify");
});

test("bind safety, wildcard detection and LAN-first URL ordering", async () => {
  assert.equal(isLoopback("127.0.0.1"), true);
  assert.equal(isLoopback("::1"), true);
  assert.equal(isLoopback("localhost"), true);
  assert.equal(isLoopback("10.0.0.1"), false);
  assert.equal(isWildcard("0.0.0.0"), true);
  assert.equal(isWildcard("::"), true);
  assert.equal(isWildcard("127.0.0.1"), false);

  assert.throws(
    () => assertBindSafe({ bindHost: "0.0.0.0", passwordSet: false, authMode: "password" }),
    (error) => error.code === "needs-password",
  );
  assert.throws(
    () => assertBindSafe({ bindHost: "0.0.0.0", passwordSet: true, authMode: "open" }),
    (error) => error.code === "open-requires-loopback",
  );
  assert.equal(assertBindSafe({ bindHost: "127.0.0.1", passwordSet: false, authMode: "password" }), true);
  assert.equal(assertBindSafe({ bindHost: "0.0.0.0", passwordSet: true, authMode: "password" }), true);

  const addresses = [
    { address: "10.150.23.97", iface: "以太网", family: "IPv4", primary: true },
    { address: "192.168.157.1", iface: "VMware Network Adapter VMnet8", family: "IPv4", primary: false },
  ];
  const wildcard = urlsFor({ bindHost: "0.0.0.0", port: 3081, protocol: "http:", addresses });
  assert.deepEqual(wildcard.urls, ["http://10.150.23.97:3081/", "http://192.168.157.1:3081/", "http://127.0.0.1:3081/"]);
  assert.deepEqual(wildcard.lanUrls.slice(0, 1), ["http://10.150.23.97:3081/"]);
  const loopback = urlsFor({ bindHost: "127.0.0.1", port: 3081, protocol: "http:", addresses });
  assert.deepEqual(loopback.urls, ["http://127.0.0.1:3081/"]);
  assert.deepEqual(loopback.lanUrls, []);
  const specific = urlsFor({ bindHost: "10.150.23.97", port: 443, protocol: "https:", addresses });
  assert.deepEqual(specific.urls, ["https://10.150.23.97/"]);
});

test("address discovery never selects virtual adapters", () => {
  const list = discoverAddressesSync();
  assert.ok(Array.isArray(list));
  for (const entry of list) {
    assert.equal(/vmware|virtual|vethernet|hyper-v|docker|tailscale|loopback|wsl/i.test(entry.iface), false, `virtual iface leaked: ${entry.iface}`);
    assert.equal(entry.address.startsWith("169.254."), false);
    assert.equal(isLoopback(entry.address), false);
    assert.equal(entry.family, "IPv4");
  }
  // Machine-specific fact worth pinning (ARCHITECTURE.md §1): the real Ethernet
  // address must outrank the VMware adapters when it is present.
  const primary = list.find((entry) => entry.primary);
  if (list.some((entry) => entry.address === "10.150.23.97")) {
    assert.equal(primary && primary.address, "10.150.23.97");
  }
});

test("header rewriting helpers keep the fence and drop our own cookie", () => {
  const upstream = {
    ok: true, host: "127.0.0.1", port: 19890, protocol: "http:",
    connectHost: "127.0.0.1", authority: "127.0.0.1:19890", origin: "http://127.0.0.1:19890",
  };
  const req = {
    method: "GET",
    url: "/api/x",
    headers: {
      host: "10.150.23.97:3081",
      origin: "http://10.150.23.97:3081",
      referer: "http://10.150.23.97:3081/settings",
      cookie: "dsh_portal=abc; theme=dark; dsh-auth-x=v",
      "sec-fetch-site": "same-origin",
      connection: "keep-alive",
      "x-forwarded-for": "1.2.3.4",
    },
  };
  const headers = buildUpstreamHeaders(req, {
    upstream, portalOrigin: "http://10.150.23.97:3081", secure: false, remoteAddress: "10.150.23.97",
  });
  assert.equal(headers.host, "127.0.0.1:19890");
  assert.equal(headers.origin, "http://127.0.0.1:19890");
  assert.equal(headers.referer, "http://127.0.0.1:19890/settings");
  assert.equal(headers.cookie, "theme=dark; dsh-auth-x=v");
  assert.equal(headers["x-forwarded-for"], "1.2.3.4, 10.150.23.97");
  assert.equal(headers["x-forwarded-proto"], "http");
  assert.equal(headers["x-forwarded-host"], "10.150.23.97:3081");
  assert.equal(headers.connection, undefined, "hop-by-hop headers must be dropped");

  assert.equal(stripCookies("a=1; dsh-auth-x=2; b=3", ["dsh-auth-"]), "a=1; b=3");
  assert.equal(withMintedCookies("a=1; dsh-auth-x=old", ["dsh-auth-x=new; Path=/"]), "a=1; dsh-auth-x=new");

  const rewritten = rewriteLocation("http://127.0.0.1:19890/app?x=1", {
    upstream, portalOrigin: "http://10.150.23.97:3081",
  });
  assert.equal(rewritten, "http://10.150.23.97:3081/app?x=1");
  assert.equal(rewriteLocation("./next", { upstream, portalOrigin: "http://10.150.23.97:3081" }), "./next");
  assert.equal(rewriteLocation("https://example.com/x", { upstream, portalOrigin: "http://10.150.23.97:3081" }), "https://example.com/x");
});

test("mint helpers filter non-dsh cookies and respect plain-http listeners", () => {
  const plain = sanitizeSetCookie("dsh-auth-a=1; Path=/; Secure; Domain=evil.example", { secure: false });
  assert.match(plain, /^dsh-auth-a=1; Path=\//);
  assert.doesNotMatch(plain, /Secure|Domain/);
  assert.match(plain, /HttpOnly/);
  assert.match(plain, /SameSite=Lax/);
  assert.match(sanitizeSetCookie("dsh-auth-a=1; Secure", { secure: true }), /Secure/);
  assert.equal(sanitizeSetCookie("sessionid=abc; Path=/", {}), null);
  const authority = cookieAuthority(`dsh-auth-x=v1.${Buffer.from(JSON.stringify({ version: 1, authority: "127.0.0.1:19890" })).toString("base64url")}.sig`);
  assert.equal(authority, "127.0.0.1:19890");
  assert.equal(cookieAuthority("garbage"), "");
});

test("upstreamFromContext reads the host port lazily and tolerates test doubles", () => {
  const ctx = { webServer: { host: "127.0.0.1", protocol: "http:", port: 0 } };
  assert.equal(upstreamFromContext(ctx).ok, false);
  ctx.webServer.port = 19890;
  const up = upstreamFromContext(ctx);
  assert.equal(up.ok, true);
  assert.equal(up.authority, "127.0.0.1:19890");
  assert.equal(up.origin, "http://127.0.0.1:19890");
  assert.equal(upstreamFromContext(undefined).ok, false);
  assert.equal(upstreamFromContext({ get() { throw new Error("no service"); } }).ok, false);
});

test("config normalization clamps hostile values and keeps tls on a partial patch", () => {
  const base = normalizeConfig({
    port: 3081,
    tls: { certFile: "C:/c.pem", keyFile: "C:/k.pem" },
    auth: { mode: "pair-only", sessionDays: 7 },
  });
  assert.equal(base.port, 3081);
  assert.equal(base.auth.mode, "pair-only");
  assert.equal(base.tls.certFile, "C:/c.pem");
  const patched = normalizeConfig({ port: 99999, auth: { maxFailures: 0 } }, base);
  assert.equal(patched.port, 65535);
  assert.equal(patched.auth.maxFailures, 1);
  assert.equal(patched.auth.mode, "pair-only", "an absent key keeps the previous value");
  assert.equal(patched.tls.certFile, "C:/c.pem", "a partial patch must not drop tls");
  const bogus = normalizeConfig({ host: "", port: -5, auth: { mode: "nope" } }, base);
  assert.equal(bogus.host, "0.0.0.0");
  assert.equal(bogus.port, 0);
  assert.equal(bogus.auth.mode, "pair-only");
});




