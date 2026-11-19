/**
 * dsh-remote-portal — relay + tunnel end-to-end tests.
 *
 * These start a real relay, a real tunnel agent and a dummy "gateway" upstream,
 * then drive HTTP and WebSocket traffic through the whole path:
 *
 *   test client → relay visitor port → mux frames → tunnel agent → gateway
 *
 * Mocking any hop would hide the only things worth pinning here: prefix
 * stripping, header forwarding, stream lifecycle, upgrade pass-through, and the
 * two failure modes that matter in production (wrong token, host offline).
 *
 * Run with:  node --test
 */
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { apply } from "../index.js";
import { createRelay, tunnelIdFor } from "../tools/relay.mjs";
import { createTunnel } from "../lib/tunnel.mjs";
import * as agentFraming from "../lib/tunnel.mjs";
import * as relayFraming from "../tools/relay.mjs";

const quiet = { info() {}, warn() {}, error() {} };
const HERE = dirname(fileURLToPath(import.meta.url));
const TLS_CERT = join(HERE, "fixtures", "tls", "cert.pem");
const TLS_KEY = join(HERE, "fixtures", "tls", "key.pem");
const cleanups = [];
const dirs = [];

function tmpDir() {
  const dir = mkdtempSync(join(tmpdir(), "drp-relay-"));
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

/** Accept sockets explicitly so close() cannot hang on an upgraded one. */
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

/** Stand-in for the portal gateway: echoes what actually arrived. */
async function startGatewayDouble() {
  const server = http.createServer((req, res) => {
    const body = JSON.stringify({
      method: req.method,
      url: req.url,
      headers: req.headers,
    });
    res.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "x-gateway-double": "1",
      "content-length": Buffer.byteLength(body),
    });
    res.end(body);
  });
  // Minimal upgrade handler: complete the handshake, then echo bytes.
  server.on("upgrade", (req, socket) => {
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
      "upgrade: websocket\r\nconnection: Upgrade\r\n" +
      "sec-websocket-accept: test\r\n\r\n",
    );
    socket.on("data", (chunk) => {
      try { socket.write(Buffer.concat([Buffer.from("echo:"), chunk])); } catch { /* gone */ }
    });
    socket.on("error", () => { try { socket.destroy(); } catch { /* gone */ } });
  });
  const port = await listen(server);
  return port;
}

async function startRelay(tokens, overrides = {}) {
  const relay = createRelay({
    tokens,
    agentPort: 0,
    agentHost: "127.0.0.1",
    httpPort: 0,
    httpHost: "127.0.0.1",
    tlsPort: 0,
    tlsCert: "",
    tlsKey: "",
    publicUrl: "http://relay.test",
    prefix: "/__t",
    maxStreams: 32,
    requestTimeout: 10000,
    ...overrides,
  });
  const ports = await relay.start();
  cleanups.push(() => relay.stop());
  return { relay, ...ports };
}

/** Ask the OS for an unused port (the relay only opens TLS when given a number). */
async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitFor(predicate, { timeoutMs = 5000, label = "condition" } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timed out waiting for ${label}`);
}

function request(port, path, { method = "GET", headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks),
      }));
    });
    req.on("error", reject);
    req.end();
  });
}

function httpsRequest(port, path, { headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      { host: "127.0.0.1", port, path, method: "GET", headers, agent: false, rejectUnauthorized: false },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve({
          status: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        }));
      },
    );
    req.on("error", reject);
    req.end();
  });
}

/** Start a tunnel and wait until the relay reports it online. */
async function connectTunnel({ agentPort, token, targetPort }) {
  const tunnel = createTunnel({
    url: `tcp://127.0.0.1:${agentPort}`,
    token,
    targetPort: () => targetPort,
    log: quiet,
  });
  cleanups.push(() => tunnel.stop());
  await tunnel.start();
  await waitFor(() => tunnel.status().status === "online", { label: "tunnel online" });
  return tunnel;
}

test("Chrome loads each mobile asset once through the relay, with and without host tags", { timeout: 60000 }, async (t) => {
  const chrome = process.env.CHROME_PATH || "google-chrome";
  const browser = spawnSync(chrome, ["--version"]);
  if (!process.env.CHROME_PATH && browser.error?.code === "ENOENT") {
    return t.skip("Chrome not found; set CHROME_PATH to enable this test");
  }
  assert.equal(browser.status, 0, String(browser.error || browser.stderr));

  let inject;
  const routes = new Map();
  apply({
    logger: quiet,
    webServer: {
      host: "127.0.0.1",
      register(route) { routes.set(route.path, route.handler); },
    },
    get() { return undefined; },
    on(name, listener) { if (name === "webserver/index-inject") inject = listener; },
    effect(fn, label) { if (/(control routes|index injections)$/.test(label)) fn(); },
  }, { stateDir: tmpDir() });
  const rows = [];
  inject(rows);

  const client = readFileSync(join(HERE, "..", "client.js"));
  const received = [];
  const assetRoute = "/dsh-remote-portal/assets";
  const targetPort = await listen(http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    if (url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(`<!doctype html><html><head><base href="./">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        ${url.searchParams.has("host") ? rows.map(row => row.html).join("") : ""}
        <script>window.__ModuleLoader__ = { load(plugin) {
          plugin.factory(() => ({})).apply({ effect: fn => fn() });
        } };</script>
        <script defer src="./client.js"></script></head><body></body></html>`);
    } else if (url.pathname === "/client.js") {
      res.writeHead(200, { "content-type": "text/javascript" }).end(client);
    } else if (url.pathname.startsWith(assetRoute + "/")) {
      received.push(url.pathname.slice(assetRoute.length + 1));
      routes.get(assetRoute)(req, res);
    } else {
      res.writeHead(404).end();
    }
  }));
  const token = "test-token-browser-mobile-assets";
  const mount = `/__t/${tunnelIdFor(token)}/`;
  const { httpPort, agentPort } = await startRelay([token]);
  await connectTunnel({ agentPort, token, targetPort });

  for (const host of [true, false]) {
    const css = host ? "link[data-drp=mobile-css-host]" : "style[data-drp=mobile-css]";
    const js = host ? "script[data-drp=mobile-js-host]" : "script[data-drp=mobile-js]";
    const expr = `(async () => {
      const limit = performance.now() + 3000;
      const ready = () => document.querySelector(${JSON.stringify(css)})?.sheet?.cssRules.length > 0 &&
        window.__DRP_MOBILE__?.active === true;
      while (!ready() && performance.now() < limit) await new Promise(r => setTimeout(r, 25));
      return {
        active: ready() && document.documentElement.hasAttribute("data-drp-mobile"),
        script: !!document.querySelector(${JSON.stringify(js)}),
        assets: performance.getEntriesByType("resource")
          .filter(entry => /\\/assets\\/mobile\\.(?:css|js)$/.test(new URL(entry.name).pathname))
          .map(entry => [new URL(entry.name).pathname, entry.initiatorType]).sort(),
      };
    })()`;
    received.length = 0;
    const { stdout } = await promisify(execFile)(process.execPath, [
      join(HERE, "..", "tools", "cdp.mjs"), "eval",
      `http://127.0.0.1:${httpPort}${mount}?drp=mobile${host ? "&host=1" : ""}`,
      expr, "--wait", "100", "--w", "390", "--h", "844", "--mobile",
    ], { env: { ...process.env, CHROME_PATH: chrome }, timeout: 26000 });
    assert.deepEqual(JSON.parse(stdout), {
      active: true,
      script: true,
      assets: [
        [`${mount}dsh-remote-portal/assets/mobile.css`, host ? "link" : "fetch"],
        [`${mount}dsh-remote-portal/assets/mobile.js`, host ? "script" : "fetch"],
      ],
    });
    assert.deepEqual(received.sort(), ["mobile.css", "mobile.js"]);
  }
});

test("the relay shares only versioned public mobile assets and separates encoding variants", async () => {
  const token = "test-token-public-mobile-assets";
  const root = `/__t/${tunnelIdFor(token)}`;
  const revision = "a".repeat(43);
  const asset = `/dsh-remote-portal/assets/mobile.css?v=${revision}`;
  let requests = 0;
  const targetPort = await listen(http.createServer((req, res) => {
    requests++;
    const headers = {
      "content-type": "text/css",
      "cache-control": "public, max-age=31536000, immutable",
      vary: "Accept-Encoding",
      etag: '"asset"',
    };
    const variant = req.headers["accept-encoding"] || "identity";
    if (req.url.includes("mobile.js")) headers.vary = "Accept-Encoding, Cookie";
    if (req.headers["if-none-match"] === headers.etag) {
      res.writeHead(304, headers).end();
    } else if (req.url.startsWith("/assets/") && !req.headers.cookie) {
      res.writeHead(401).end();
    } else {
      res.writeHead(200, headers).end(`${variant}:${requests}`);
    }
  }));
  const { relay, httpPort, agentPort } = await startRelay([token]);
  await connectTunnel({ agentPort, token, targetPort });
  const get = (path, headers) => request(httpPort, root + path, { headers });
  const stored = () => relay.stats.cacheStored;
  const identity = await get(asset);
  assert.equal(identity.body.toString(), "identity:1");
  assert.equal((await get(asset, { cookie: "session=another" })).headers["x-drp-cache"], "hit");
  assert.equal(requests, 1);
  const encoded = await get(asset, { "accept-encoding": "gzip" });
  assert.equal(encoded.body.toString(), "gzip:2");
  assert.equal((await get(asset, { "accept-encoding": "gzip" })).headers["x-drp-cache"], "hit");
  const conditional = await get(asset, { "if-none-match": '"asset"' });
  assert.equal(conditional.status, 304);
  assert.equal(requests, 3, "client conditionals must reach the origin");
  await get(asset, { authorization: "Bearer dummy" });
  await get(asset, { "cache-control": "no-cache" });
  assert.equal(requests, 5);
  const before = stored();
  const cookieVariant = asset.replace("mobile.css", "mobile.js");
  await get(cookieVariant, { cookie: "session=first" });
  assert.equal((await get(cookieVariant, { cookie: "session=second" })).headers["x-drp-cache"], undefined);
  const protectedAsset = "/assets/private-12345678.js";
  assert.equal((await get(protectedAsset, { cookie: "session=first" })).status, 200);
  assert.equal((await get(protectedAsset)).status, 401);
  assert.equal(stored(), before);
});

// ───────────────────────────────────────────────────────────────────────────

test("forwards an HTTP request through the tunnel and strips the routing prefix", async () => {
  const token = "test-token-http";
  const id = tunnelIdFor(token);
  const gatewayPort = await startGatewayDouble();
  const { httpPort, agentPort } = await startRelay([token]);
  await connectTunnel({ agentPort, token, targetPort: gatewayPort });

  const res = await request(httpPort, `/__t/${id}/api/session?tail=1`, {
    headers: { "x-test-header": "forwarded" },
  });
  assert.equal(res.status, 200, `expected 200, body=${res.body.toString().slice(0, 200)}`);
  assert.equal(res.headers["x-gateway-double"], "1", "the upstream's headers must survive");
  const seen = JSON.parse(res.body.toString());
  assert.equal(seen.url, "/api/session?tail=1", "the routing prefix must be stripped");
  assert.equal(seen.headers["x-test-header"], "forwarded", "client headers must be forwarded");
  assert.equal(seen.headers["x-forwarded-proto"], "http", "the relay tags the original scheme");
  assert.ok(seen.headers["x-forwarded-for"], "the relay passes the client address along");
});

test("serves the relay's own health endpoint without touching the tunnel", async () => {
  const token = "test-token-health";
  const { httpPort } = await startRelay([token]);
  const res = await request(httpPort, "/__relay/health");
  assert.equal(res.status, 200);
  const health = JSON.parse(res.body.toString());
  assert.equal(health.ok, true);
  assert.equal(health.tunnels.length, 1);
  assert.equal(health.tunnels[0].connected, false, "nothing is connected yet");
});

test("a tunnel URL without its trailing slash redirects to one", async () => {
  // Relative links resolve against the parent directory, so /__t/<id> would make
  // the login form post to /__t/__portal/login and the relay would read
  // "__portal" as a tunnel id.
  const token = "test-token-slash";
  const id = tunnelIdFor(token);
  const { httpPort } = await startRelay([token]);
  const res = await request(httpPort, `/__t/${id}`);
  assert.equal(res.status, 301);
  assert.equal(res.headers.location, `/__t/${id}/`);
});

test("an unknown tunnel id gets a page, not a proxy attempt", async () => {
  const { httpPort } = await startRelay(["only-this-token"]);
  const res = await request(httpPort, "/__t/doesnotexist/");
  assert.equal(res.status, 404);
  assert.match(res.body.toString(), /Unknown tunnel/i);
  assert.match(String(res.headers["content-security-policy"]), /frame-ancestors 'none'/);
});

test("a known but offline tunnel explains itself with 503", async () => {
  const token = "test-token-offline";
  const id = tunnelIdFor(token);
  const { httpPort } = await startRelay([token]);
  const res = await request(httpPort, `/__t/${id}/`);
  assert.equal(res.status, 503);
  assert.match(res.body.toString(), /not connected/i);
});

test("a tunnel with the wrong token never comes online", async () => {
  const { agentPort } = await startRelay(["relay-expects-this"]);
  const tunnel = createTunnel({
    url: `tcp://127.0.0.1:${agentPort}`,
    token: "agent-has-that",
    targetPort: () => 1,
    log: quiet,
  });
  cleanups.push(() => tunnel.stop());
  await tunnel.start();
  await waitFor(() => tunnel.status().status !== "connecting", { label: "rejection" });
  assert.notEqual(tunnel.status().status, "online", "an unauthorized agent must not attach");
  assert.match(String(tunnel.status().lastError || ""), /unauthorized|closed/i);
});

test("WebSocket upgrades are tunnelled byte-for-byte", async () => {
  const token = "test-token-ws";
  const id = tunnelIdFor(token);
  const gatewayPort = await startGatewayDouble();
  const { httpPort, agentPort } = await startRelay([token]);
  await connectTunnel({ agentPort, token, targetPort: gatewayPort });

  const socket = net.connect({ host: "127.0.0.1", port: httpPort });
  const received = [];
  await new Promise((resolve, reject) => {
    socket.once("error", reject);
    socket.once("connect", () => {
      socket.write(
        `GET /__t/${id}/api/remote.mux HTTP/1.1\r\n` +
        "host: relay.test\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" +
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n",
      );
      resolve();
    });
  });
  socket.on("data", (chunk) => received.push(chunk));

  await waitFor(() => received.length > 0, { label: "handshake response" });
  const head = Buffer.concat(received).toString("latin1");
  assert.match(head, /101 Switching Protocols/, "the upstream handshake must reach the client");

  socket.write("ping-through-tunnel");
  await waitFor(
    () => Buffer.concat(received).toString("latin1").includes("echo:ping-through-tunnel"),
    { label: "echoed payload" },
  );
  socket.destroy();
});

test("serves the visitor over HTTPS and accepts a TLS agent connection", async () => {
  const token = "test-token-tls";
  const id = tunnelIdFor(token);
  const gatewayPort = await startGatewayDouble();
  const tlsPort = await freePort();
  // One certificate, two listeners: the visitor HTTPS port and the agent port.
  const { httpPort, agentPort } = await startRelay([token], {
    tlsPort,
    tlsCert: TLS_CERT,
    tlsKey: TLS_KEY,
  });
  assert.ok(tlsPort > 0, "the relay must report its TLS visitor port");

  const tunnel = createTunnel({
    url: `tls://127.0.0.1:${agentPort}`,
    token,
    targetPort: () => gatewayPort,
    log: quiet,
    // The fixture is self-signed on purpose; a real deployment uses a public CA.
    insecure: true,
  });
  cleanups.push(() => tunnel.stop());
  await tunnel.start();
  await waitFor(() => tunnel.status().status === "online", { label: "tls tunnel online" });

  const secure = await httpsRequest(tlsPort, `/__t/${id}/secure?x=1`);
  assert.equal(secure.status, 200, `expected 200 over TLS, got ${secure.status}`);
  assert.equal(JSON.parse(secure.body).url, "/secure?x=1", "the prefix is stripped over TLS too");
  assert.equal(secure.headers["x-gateway-double"], "1");

  // The plain visitor port keeps working at the same time.
  const plain = await request(httpPort, `/__t/${id}/plain`);
  assert.equal(plain.status, 200);
  assert.equal(JSON.parse(plain.body).url, "/plain");
});

test("the tunnel reconnects after the relay drops the agent socket", async () => {
  const token = "test-token-reconnect";
  const id = tunnelIdFor(token);
  const gatewayPort = await startGatewayDouble();
  const { relay, httpPort, agentPort } = await startRelay([token]);
  const tunnel = await connectTunnel({ agentPort, token, targetPort: gatewayPort });

  const entry = relay.tunnels.get(id);
  assert.ok(entry && entry.socket, "the relay should hold the agent socket");
  try { entry.socket.destroy(); } catch { /* gone */ }

  // The agent retries on a 1 s timer (RETRY_MS[0]); give it room.
  await waitFor(() => entry.socket && !entry.socket.destroyed, { timeoutMs: 8000, label: "reconnect" });
  await waitFor(() => tunnel.status().status === "online", { timeoutMs: 8000, label: "online again" });

  const res = await request(httpPort, `/__t/${id}/after-reconnect`);
  assert.equal(res.status, 200);
  assert.equal(JSON.parse(res.body.toString()).url, "/after-reconnect");
});

test("a stream that outlives the request timeout is failed, not leaked", async () => {
  const token = "test-token-timeout";
  const id = tunnelIdFor(token);
  // An upstream that never answers.
  const hanging = http.createServer(() => { /* never respond */ });
  const hangingPort = await listen(hanging);
  const { relay, httpPort, agentPort } = await startRelay([token], { requestTimeout: 1200 });
  await connectTunnel({ agentPort, token, targetPort: hangingPort });

  const startedAt = Date.now();
  const res = await request(httpPort, `/__t/${id}/slow`);
  const elapsed = Date.now() - startedAt;
  assert.equal(res.status, 504, `expected 504, got ${res.status}`);
  assert.match(res.body.toString(), /did not answer/i);
  assert.ok(elapsed < 6000, `the timeout should fire quickly, took ${elapsed} ms`);
  assert.equal(relay.tunnels.get(id).streams.size, 0, "the stream must be released");
});

test("a response that finishes above the visitor high water mark does not stall the tunnel", async () => {
  const token = "test-token-finish";
  const id = tunnelIdFor(token);
  const { relay, httpPort, agentPort } = await startRelay([token], { requestTimeout: 1500 });
  const { FRAME, encodeFrame, createFrameReader } = agentFraming;
  const incoming = [];
  const agent = net.connect(agentPort, "127.0.0.1");
  cleanups.push(() => agent.destroy());
  agent.on("data", createFrameReader((type, streamId) => {
    if (type === FRAME.REQ_END) incoming.push(streamId);
  }, assert.fail));
  agent.write(encodeFrame(FRAME.HELLO, 0, JSON.stringify({ token })));
  await waitFor(() => relay.tunnels.get(id).socket, { label: "agent attached" });

  const tunnelSocket = relay.tunnels.get(id).socket;
  const pause = tunnelSocket.pause.bind(tunnelSocket);
  let pauses = 0;
  tunnelSocket.pause = () => { pauses++; return pause(); };

  function responseHead(streamId, length) {
    return encodeFrame(FRAME.RES_HEAD, streamId, JSON.stringify({ status: 200, headers: { "content-length": length } }));
  }

  const first = request(httpPort, `/__t/${id}/large`);
  await waitFor(() => incoming.length === 1, { label: "first request" });
  const body = Buffer.alloc(128 * 1024, 65);
  const frame = encodeFrame(FRAME.RES_BODY, incoming[0], body);
  const split = frame.length - 1024;
  const prefix = Buffer.concat([responseHead(incoming[0], body.length), frame.subarray(0, split)]);
  const before = relay.stats.bytesIn;
  agent.write(prefix);
  await waitFor(() => relay.stats.bytesIn === before + prefix.length, { label: "response prefix read" });
  agent.write(Buffer.concat([frame.subarray(split), encodeFrame(FRAME.RES_END, incoming[0])]));

  const result = await first;
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, body);
  assert.ok(pauses > 0, "the large frame must trigger visitor backpressure");
  const next = request(httpPort, `/__t/${id}/next`);
  await waitFor(() => incoming.length === 2, { label: "next request" });
  agent.write(Buffer.concat([responseHead(incoming[1], 0), encodeFrame(FRAME.RES_END, incoming[1])]));
  assert.equal((await next).status, 200);
});

test("framing helpers round-trip a binary payload", async () => {
  const { encodeFrame, createFrameReader, FRAME } = await import("../tools/relay.mjs");
  const payload = Buffer.from([0, 255, 1, 254, 2]);
  const frame = encodeFrame(FRAME.RES_BODY, 42, payload);
  const frames = [];
  const reader = createFrameReader((type, id, body) => frames.push({ type, id, body }));
  // Feed it in awkward slices to exercise the partial-frame path.
  reader(frame.subarray(0, 3));
  reader(frame.subarray(3, 7));
  reader(frame.subarray(7));
  assert.equal(frames.length, 1);
  assert.equal(frames[0].type, FRAME.RES_BODY);
  assert.equal(frames[0].id, 42);
  assert.deepEqual([...frames[0].body], [...payload]);
});

for (const [name, framing, peer] of [
  ["relay", relayFraming, agentFraming],
  ["agent", agentFraming, relayFraming],
]) {
  test(`${name} decodes a fragmented maximum-size frame followed by coalesced frames`, () => {
    const { RES_BODY, RES_END, PING } = peer.FRAME;
    const body = Buffer.alloc(1024 * 1024);
    for (let i = 0; i < body.length; i++) body[i] = i % 251;
    const large = peer.encodeFrame(RES_BODY, 0x01020304, body);
    const end = peer.encodeFrame(RES_END, 0x01020304);
    const ping = peer.encodeFrame(PING, 0);
    const calls = [];
    const reader = framing.createFrameReader((...frame) => calls.push(frame), assert.fail);

    for (let i = 0; i < 9; i++) reader(large.subarray(i, i + 1));
    for (let i = 9; i < large.length - 1; i += 1024) {
      reader(large.subarray(i, Math.min(i + 1024, large.length - 1)));
    }
    assert.deepEqual(calls, []);
    reader(Buffer.concat([large.subarray(-1), end, ping]));
    assert.deepEqual(calls, [[RES_BODY, 0x01020304, body], [RES_END, 0x01020304, Buffer.alloc(0)],
      [PING, 0, Buffer.alloc(0)]]);
  });

  test(`${name} rejects an oversized frame without waiting for its payload`, () => {
    const header = Buffer.from([22, 0, 0, 0, 0, 0, 16, 0, 1]);
    const errors = [];
    const reader = framing.createFrameReader(assert.fail, (error) => errors.push(error));
    reader(header.subarray(0, 8));
    assert.deepEqual(errors, []);
    reader(header.subarray(8));
    reader(peer.encodeFrame(peer.FRAME.PING, 0));
    assert.equal(errors.length, 1);
    assert.match(errors[0].message, /frame too large: 1048577/);
    if (name === "relay") assert.equal(errors[0].firstByte, 22);
  });
}



