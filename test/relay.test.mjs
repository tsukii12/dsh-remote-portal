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
import { createGateway } from "../lib/gateway.mjs";
import { createTunnel } from "../lib/tunnel.mjs";
import * as agentFraming from "../lib/tunnel.mjs";
import * as relayFraming from "../tools/relay.mjs";

const quiet = { info() {}, warn() {}, error() {} };
const HERE = dirname(fileURLToPath(import.meta.url));
const TLS_CERT = join(HERE, "fixtures", "tls", "cert.pem");
const TLS_KEY = join(HERE, "fixtures", "tls", "key.pem");
const cleanups = [];
const dirs = [];

test("UTF-8 relay bodies survive every multibyte frame split", () => {
  const text = "你好，月亮🌙；队列、转向、@\"中文 文件.txt\"";
  for (const framing of [agentFraming, relayFraming]) {
    const body = Buffer.from(text, "utf8");
    const encoded = framing.encodeFrame(framing.FRAME.REQ_BODY, 7, body);
    for (let split = 1; split < encoded.length; split++) {
      const frames = [];
      const reader = framing.createFrameReader((type, id, payload) => frames.push({ type, id, payload }), assert.fail);
      reader(encoded.subarray(0, split));
      reader(encoded.subarray(split));
      assert.equal(frames.length, 1);
      assert.deepEqual(frames[0].payload, body);
      assert.equal(frames[0].payload.toString("utf8"), text);
    }
  }
});

test("Chinese request bodies round-trip byte-exactly through a real relay and tunnel", async () => {
  const gateway = await startGatewayDouble((req, res) => {
    const chunks = [];
    req.on("data", chunk => chunks.push(chunk));
    req.on("end", () => res.end(Buffer.concat(chunks)));
    return true;
  });
  const token = "utf8-roundtrip-local";
  const { agentPort, httpPort } = await startRelay([token]);
  await connectTunnel({ agentPort, token, targetPort: gateway });
  const body = Buffer.from(JSON.stringify({ text: "你好🌙，排队、转向与中文提及" }));
  const result = await request(httpPort, `/__t/${tunnelIdFor(token)}/utf8`, { method: "POST", body, headers: { "content-type": "application/json", "content-length": body.length } });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, body);
});

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
async function startGatewayDouble(serve) {
  const server = http.createServer((req, res) => {
    if (serve?.(req, res)) return;
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
      "HTTP/1.1 103 Early Hints\r\nLink: </asset>; rel=preload; as=script\r\n\r\n" +
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

function request(port, path, { method = "GET", headers = {}, body, localAddress } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, method, headers, localAddress }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks),
      }));
    });
    req.on("error", reject);
    req.end(body);
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

const visitorAuthHeaders = { accept: "application/json", "user-agent": "same phone browser" };
const forgedVisitorHeaders = {
  "x-forwarded-for": "203.0.113.42",
  "x-drp-tunnel-visitor": "made-up-key 203.0.113.42",
};
const testPassword = "correct horse battery";

async function portalWithRelay(agentPort, token) {
  let upgradeHeaders;
  const upstream = http.createServer((req, res) => res.end(JSON.stringify(req.headers)));
  upstream.on("upgrade", (req, socket) => {
    upgradeHeaders = req.headers;
    socket.write("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
  });
  const upstreamPort = await listen(upstream);
  const gateway = createGateway({
    ctx: { webServer: { host: "127.0.0.1", port: upstreamPort, protocol: "http:" } },
    config: {
      enabled: true, host: "127.0.0.1", port: 0, auth: { maxFailures: 2 },
      tunnel: { url: `tcp://127.0.0.1:${agentPort}`, token },
    },
    stateDir: tmpDir(), log: quiet,
  });
  cleanups.push(() => gateway.stop());
  await gateway.setPassword(testPassword);
  await gateway.start();
  await waitFor(() => gateway.status().public.state === "online", { label: "gateway tunnel online" });
  return { gateway, upgradeHeaders: () => upgradeHeaders };
}

async function visitorPair(gateway, httpPort, mount, options) {
  const { token } = await gateway.mintPairing({ ttlSeconds: 120 });
  const res = await request(httpPort, `${mount}/__portal/pair?t=${encodeURIComponent(token)}`, options);
  assert.equal(res.status, 303);
  return res.headers["set-cookie"].find(line => line.startsWith("dsh_portal=")).split(";")[0];
}

function visitorLogin(port, mount, password, options = {}) {
  const body = new URLSearchParams({ password }).toString();
  return request(port, `${mount}/__portal/login`, {
    ...options, method: "POST", body,
    headers: { ...visitorAuthHeaders, ...options.headers, "content-type": "application/x-www-form-urlencoded",
      "content-length": Buffer.byteLength(body) },
  });
}

test("real relay separates same-UA visitor pairing, revocation and lockout by socket address", async (t) => {
  const token = "test-token-visitor-identity";
  const mount = `/__t/${tunnelIdFor(token)}`;
  const { httpPort, agentPort } = await startRelay([token]);
  const { gateway, upgradeHeaders } = await portalWithRelay(agentPort, token);
  const headers = { ...visitorAuthHeaders, ...forgedVisitorHeaders };
  const a = { localAddress: "127.0.0.2", headers };
  const b = { localAddress: "127.0.0.3", headers };
  try {
    await Promise.all([a, b].map(opts => request(httpPort, "/__relay/health", opts)));
  } catch (error) {
    if (error.code === "EADDRNOTAVAIL") return t.skip("distinct loopback source addresses are unavailable");
    throw error;
  }
  const first = await visitorPair(gateway, httpPort, mount, a);
  const second = await visitorPair(gateway, httpPort, mount, b);
  const devices = gateway.devices().sort((x, y) => x.ip.localeCompare(y.ip));
  assert.deepEqual(devices.map(d => [d.ip, d.ua, d.sessions]), [
    ["127.0.0.2", headers["user-agent"], 1],
    ["127.0.0.3", headers["user-agent"], 1],
  ]);
  assert.notEqual(devices[0].id, devices[1].id);

  const authenticated = (port, address, cookie) => request(port, mount + "/api/who", {
    localAddress: address, headers: { ...headers, cookie },
  });
  assert.equal((await authenticated(httpPort, a.localAddress, first)).status, 200);
  assert.equal(await gateway.revokeDevice(devices[0].id), true);
  assert.equal((await authenticated(httpPort, a.localAddress, first)).status, 401);
  const survivor = await authenticated(httpPort, b.localAddress, second);
  assert.equal(survivor.status, 200);
  const seen = JSON.parse(survivor.body);
  assert.equal(seen["x-forwarded-for"], b.localAddress);
  assert.equal(seen["x-drp-tunnel-visitor"], undefined);

  await new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port: httpPort, path: mount + "/api/ws",
      localAddress: b.localAddress, headers: { ...headers, cookie: second, connection: "Upgrade", upgrade: "websocket" } });
    req.once("upgrade", (_res, socket) => { socket.destroy(); resolve(); });
    req.once("response", res => { res.resume(); reject(new Error(`unexpected HTTP ${res.statusCode} for upgrade`)); });
    req.once("error", reject);
    req.end();
  });
  assert.equal(upgradeHeaders()["x-forwarded-for"], b.localAddress);
  assert.equal(upgradeHeaders()["x-drp-tunnel-visitor"], undefined);
  assert.equal(gateway.accessLog().find(entry => entry.path === "/api/ws").ip, b.localAddress);

  assert.equal((await visitorLogin(httpPort, mount, "wrong", a)).status, 401);
  const spoofed = { ...a, headers: { ...headers, "x-forwarded-for": b.localAddress,
    "x-drp-tunnel-visitor": `made-up-key ${b.localAddress}` } };
  assert.equal((await visitorLogin(httpPort, mount, "wrong", spoofed)).status, 429);
  assert.equal((await visitorLogin(httpPort, mount, testPassword, a)).status, 429);
  assert.equal((await visitorLogin(httpPort, mount, testPassword, b)).status, 303);
});

test("direct clients cannot spoof a different visitor or send the internal header upstream", async () => {
  const token = "test-token-direct-spoof";
  const { agentPort } = await startRelay([token]);
  const { gateway } = await portalWithRelay(agentPort, token);
  const port = gateway.status().port;
  const headers = { ...visitorAuthHeaders, ...forgedVisitorHeaders };
  const cookie = await visitorPair(gateway, port, "", { headers });
  assert.deepEqual(gateway.devices().map(d => d.ip), ["127.0.0.1"]);
  const proxied = await request(port, "/api/who", { headers: { ...headers, cookie } });
  assert.equal(proxied.status, 200);
  const seen = JSON.parse(proxied.body);
  assert.equal(seen["x-forwarded-for"], "127.0.0.1");
  assert.equal(seen["x-drp-tunnel-visitor"], undefined);
  assert.equal((await visitorLogin(port, "", "wrong", { headers })).status, 401);
  assert.equal((await visitorLogin(port, "", "wrong", { headers: { ...headers, "x-forwarded-for": "203.0.113.43" } })).status, 429);
  assert.equal((await visitorLogin(port, "", testPassword)).status, 429);
});

test("legacy relay opens use a stable tunnel identity instead of forwarding headers", async () => {
  const token = "test-token-legacy-visitor-identity";
  const { createFrameReader, encodeFrame, FRAME } = relayFraming;
  let peer;
  const heads = new Map();
  const agentPort = await listen(net.createServer(socket => {
    peer = socket;
    socket.on("data", createFrameReader((type, id, payload) => {
      if (type === FRAME.HELLO) socket.write(encodeFrame(FRAME.WELCOME, 0, JSON.stringify({ tunnelId: tunnelIdFor(token) })));
      if (type === FRAME.RES_HEAD) heads.set(id, JSON.parse(payload));
    }, assert.fail));
  }));
  const { gateway } = await portalWithRelay(agentPort, token);
  for (const id of [1, 2]) {
    const pairing = await gateway.mintPairing({ ttlSeconds: 120 });
    peer.write(encodeFrame(FRAME.REQ_HEAD, id, JSON.stringify({
      method: "GET", path: `/__portal/pair?t=${encodeURIComponent(pairing.token)}`,
      headers: { ...visitorAuthHeaders, ...forgedVisitorHeaders, "x-forwarded-for": `203.0.113.${id}` },
    })));
    peer.write(encodeFrame(FRAME.REQ_END, id));
    await waitFor(() => heads.has(id), { label: "legacy relay pairing response" });
    assert.equal(heads.get(id).status, 303);
  }
  assert.deepEqual(gateway.devices().map(d => [d.ip, d.sessions]), [[`relay:${tunnelIdFor(token)}`, 2]]);
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

test("the relay home and missing-route pages are localized", async () => {
  const { httpPort } = await startRelay(["test-token-local-pages"]);
  for (const [lang, home, notFound] of [
    ["en", "dsh remote portal relay", "Not found"],
    ["zh", "dsh 远程访问中继", "找不到页面"],
  ]) {
    const options = { headers: { "accept-language": lang } };
    for (const [path, status, title] of [["/", 200, home], ["/missing", 404, notFound]]) {
      const res = await request(httpPort, path, options);
      assert.equal(res.status, status);
      assert.equal(res.headers["content-language"], lang);
      assert.equal(res.headers.vary, "Accept-Language");
      assert.ok(res.body.toString().includes(`<h1>${title}</h1>`));
    }
  }
});

test("an unknown tunnel id gets a page, not a proxy attempt", async () => {
  const { httpPort } = await startRelay(["only-this-token"]);
  const res = await request(httpPort, "/__t/doesnotexist/");
  assert.equal(res.status, 404);
  assert.match(res.body.toString(), /Unknown tunnel/i);
  assert.match(String(res.headers["content-security-policy"]), /frame-ancestors 'none'/);
  const zh = await request(httpPort, "/__t/doesnotexist/", { headers: { "accept-language": "zh-TW" } });
  assert.equal(zh.status, 404);
  assert.equal(zh.headers["content-language"], "zh");
  assert.equal(zh.headers.vary, "Accept-Language");
  assert.match(zh.body.toString(), /找不到隧道.*<code>doesnotexist<\/code>/);
});

test("a known but offline tunnel explains itself with 503", async () => {
  const token = "test-token-offline";
  const id = tunnelIdFor(token);
  const { httpPort } = await startRelay([token]);
  const res = await request(httpPort, `/__t/${id}/`);
  assert.equal(res.status, 503);
  assert.match(res.body.toString(), /not connected/i);
  assert.equal(res.headers["content-language"], "en");
  assert.equal(res.headers.vary, "Accept-Language");
  assert.match(res.body.toString(), /<html lang="en">/);
  assert.match(res.body.toString(), /<h1>The host is offline<\/h1>/);
  for (const [preferred, lang] of [
    ["zh", "zh"],
    ["zh-CN", "zh"],
    ["en-US;q=0.5, zh-Hant-TW;q=0.9", "zh"],
    ["en-US, zh-CN;q=0.8", "en"],
    ["fr-FR, zh;q=0", "en"],
  ]) {
    const localized = await request(httpPort, `/__t/${id}/`, { headers: { "accept-language": preferred } });
    assert.equal(localized.status, 503);
    assert.equal(localized.headers["content-language"], lang);
    assert.equal(localized.headers.vary, "Accept-Language");
    assert.match(localized.body.toString(), new RegExp(`<html lang="${lang}">`));
    assert.ok(localized.body.toString().includes(lang === "zh" ? "<h1>主机已离线</h1>" : "<h1>The host is offline</h1>"));
  }
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
  const { httpPort, agentPort } = await startRelay([token], { requestTimeout: 750, httpIdleTimeout: 750 });
  await connectTunnel({ agentPort, token, targetPort: gatewayPort });

  const socket = net.connect({ host: "127.0.0.1", port: httpPort });
  cleanups.push(() => socket.destroy());
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

  await new Promise((resolve) => setTimeout(resolve, 900));
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

test("a saturated tunnel and a failed upstream get distinct localized error pages", async () => {
  const token = "test-token-localized-errors";
  const path = `/__t/${tunnelIdFor(token)}/`;
  let heldResponse;
  const upstream = http.createServer((req, res) => {
    if (req.url === "/hold") heldResponse = res;
    else req.socket.destroy();
  });
  const targetPort = await listen(upstream);
  const { httpPort, agentPort } = await startRelay([token], { maxStreams: 1 });
  await connectTunnel({ agentPort, token, targetPort });
  const held = request(httpPort, path + "hold");
  const variants = [
    ["en", "The relay is busy", "Tunnel error"],
    ["zh", "中继繁忙", "隧道连接出错"],
  ];
  async function checkPage(route, status, lang, heading) {
    const res = await request(httpPort, path + route, { headers: { "accept-language": lang } });
    assert.equal(res.status, status);
    assert.equal(res.headers["content-language"], lang);
    assert.equal(res.headers.vary, "Accept-Language");
    assert.ok(res.body.toString().includes(`<h1>${heading}</h1>`));
  }
  try {
    await waitFor(() => heldResponse, { label: "the only stream to reach the upstream" });
    for (const [lang, heading] of variants) await checkPage("fail", 503, lang, heading);
  } finally {
    heldResponse?.end("released");
    await held;
  }
  for (const [lang, , heading] of variants) await checkPage("fail", 502, lang, heading);
});

test("a stream that outlives the request timeout is failed, not leaked", async () => {
  const token = "test-token-timeout";
  const id = tunnelIdFor(token);
  // An upstream that never answers.
  let upstreamClosed = false;
  const hanging = http.createServer((_req, res) => {
    res.writeEarlyHints({ link: "</asset>; rel=preload; as=script" });
    res.on("close", () => { upstreamClosed = true; });
  });
  const hangingPort = await listen(hanging);
  const { relay, httpPort, agentPort } = await startRelay([token], { requestTimeout: 1200 });
  await connectTunnel({ agentPort, token, targetPort: hangingPort });

  const startedAt = Date.now();
  const res = await request(httpPort, `/__t/${id}/slow`);
  const elapsed = Date.now() - startedAt;
  assert.equal(res.status, 504, `expected 504, got ${res.status}`);
  assert.match(res.body.toString(), /did not answer/i);
  const zh = await request(httpPort, `/__t/${id}/slow`, { headers: { "accept-language": "zh-CN" } });
  assert.equal(zh.status, 504);
  assert.equal(zh.headers["content-language"], "zh");
  assert.equal(zh.headers.vary, "Accept-Language");
  assert.match(zh.body.toString(), /主机响应超时/);
  assert.ok(elapsed < 6000, `the timeout should fire quickly, took ${elapsed} ms`);
  assert.equal(relay.tunnels.get(id).streams.size, 0, "the stream must be released");
  await waitFor(() => upstreamClosed, { label: "timed-out upstream closed" });
});

test("HTTP data refreshes the idle timeout, but a stalled body is aborted", async () => {
  const token = "test-token-http-idle";
  const id = tunnelIdFor(token);
  const target = http.createServer((req, res) => {
    res.writeHead(200);
    res.write("start");
    const count = req.url === "/active" ? 5 : 1;
    let sent = 0;
    const timer = setInterval(() => {
      res.write(" chunk");
      if (++sent === count) {
        clearInterval(timer);
        if (req.url === "/active") res.end(" end");
      }
    }, 200);
    res.once("close", () => clearInterval(timer));
  });
  const targetPort = await listen(target);
  const { relay, httpPort, agentPort } = await startRelay([token], {
    requestTimeout: 750,
    httpIdleTimeout: 500,
  });
  await connectTunnel({ agentPort, token, targetPort });

  const active = await request(httpPort, `/__t/${id}/active`);
  assert.equal(active.status, 200);
  assert.equal(active.body.toString(), "start chunk chunk chunk chunk chunk end");

  const stalled = await new Promise((resolve, reject) => {
    const req = http.get({ host: "127.0.0.1", port: httpPort, path: `/__t/${id}/stalled` }, (res) => {
      res.setEncoding("utf8");
      let body = "";
      res.on("data", (chunk) => { body += chunk; });
      res.on("aborted", () => resolve({ body, complete: res.complete }));
      res.on("error", reject);
      res.on("end", () => reject(new Error("the stalled HTTP response ended normally")));
    });
    req.on("error", reject);
    req.setTimeout(3000, () => req.destroy(new Error("relay did not abort the stalled HTTP response")));
  });
  assert.deepEqual(stalled, { body: "start chunk", complete: false });
  assert.equal(relay.tunnels.get(id).streams.size, 0, "the stream must be released");
});

test("a partial WebSocket handshake is subject to the header deadline", async () => {
  const token = "test-token-ws-header-timeout";
  const id = tunnelIdFor(token);
  const target = http.createServer();
  let upstreamClosed = false;
  target.on("upgrade", (_req, socket) => {
    socket.write("HTTP/1.1 101 Switching Protocols\r\n");
    socket.once("end", () => socket.end());
    socket.once("close", () => { upstreamClosed = true; });
    socket.resume();
  });
  const targetPort = await listen(target);
  const { relay, httpPort, agentPort } = await startRelay([token], { requestTimeout: 500 });
  await connectTunnel({ agentPort, token, targetPort });
  const socket = net.connect(httpPort, "127.0.0.1");
  cleanups.push(() => socket.destroy());
  const data = await new Promise((resolve, reject) => {
    let data = "";
    socket.on("data", (chunk) => { data += chunk; });
    socket.on("error", reject);
    socket.on("close", () => resolve(data));
    socket.setTimeout(2000, () => socket.destroy(new Error("relay did not close the incomplete upgrade")));
    socket.write(`GET /__t/${id}/ws HTTP/1.1\r\nHost: relay.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`);
  });
  assert.equal(data, "HTTP/1.1 101 Switching Protocols\r\n");
  assert.equal(relay.tunnels.get(id).streams.size, 0, "the stream must be released");
  await waitFor(() => upstreamClosed, { label: "timed-out upgrade upstream closed" });
});

test("an interim WebSocket response does not clear the header deadline", async () => {
  const token = "test-token-ws-early-hints";
  const id = tunnelIdFor(token);
  const target = http.createServer();
  const hints = "HTTP/1.1 103 Early Hints\r\nLink: </asset>; rel=preload; as=script\r\n\r\n";
  target.on("upgrade", (_req, socket) => {
    socket.write(hints);
    socket.once("end", () => socket.end());
    socket.resume();
  });
  const targetPort = await listen(target);
  const { relay, httpPort, agentPort } = await startRelay([token], { requestTimeout: 500 });
  await connectTunnel({ agentPort, token, targetPort });
  const socket = net.connect(httpPort, "127.0.0.1");
  cleanups.push(() => socket.destroy());
  const data = await new Promise((resolve, reject) => {
    let data = "";
    socket.on("data", (chunk) => { data += chunk; });
    socket.on("error", reject);
    socket.on("close", () => resolve(data));
    socket.setTimeout(2000, () => socket.destroy(new Error("relay did not close the stalled upgrade after 103")));
    socket.write(`GET /__t/${id}/ws HTTP/1.1\r\nHost: relay.test\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`);
  });
  assert.equal(data, hints);
  assert.equal(relay.tunnels.get(id).streams.size, 0, "the stream must be released");
});

test("a timeout cancels a negotiated response before a late body can exhaust credit", async () => {
  const token = "test-token-timeout-response-window";
  const path = `/__t/${tunnelIdFor(token)}`;
  let lateResponse;
  let upstreamClosed = false;
  const port = await listen(http.createServer((req, res) => {
    if (req.url !== "/late") { res.end("ok"); return; }
    lateResponse = res;
    req.socket.once("close", () => { upstreamClosed = true; });
  }));
  const { relay, httpPort, agentPort } = await startRelay([token], { requestTimeout: 500 });
  await connectTunnel({ agentPort, token, targetPort: port });
  const entry = relay.tunnels.get(tunnelIdFor(token));
  const agent = entry.socket;
  assert.equal(entry.responseWindow, 256 * 1024);

  assert.equal((await request(httpPort, path + "/late")).status, 504);
  assert.equal(entry.streams.size, 0);
  assert.ok(lateResponse, "the gateway must have received the request");
  if (!lateResponse.destroyed) lateResponse.end(Buffer.alloc(1024 * 1024));
  await waitFor(() => upstreamClosed, {
    timeoutMs: 1200, label: "upstream cancellation",
  });
  assert.equal((await request(httpPort, path + "/next")).body.toString(), "ok");
  assert.equal(entry.socket, agent, "the tunnel must not reconnect to clean up the stream");
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

test("a stalled visitor does not pause a negotiated tunnel or block other streams", { timeout: 10000 }, async () => {
  const token = "test-token-slow-visitor";
  const path = `/__t/${tunnelIdFor(token)}`;
  const total = 16 * 1024 * 1024;
  const chunk = Buffer.alloc(64 * 1024, 42);
  let produced = 0;
  const gatewayPort = await startGatewayDouble((req, res) => {
    if (req.url !== "/bulk") return false;
    res.setHeader("content-length", total);
    const write = () => {
      while (produced < total && !res.destroyed) {
        produced += chunk.length;
        if (!res.write(chunk)) {
          res.once("drain", write);
          return;
        }
      }
      res.end();
    };
    write();
    return true;
  });
  const { relay, httpPort, agentPort } = await startRelay([token]);
  await connectTunnel({ agentPort, token, targetPort: gatewayPort });
  const connection = relay.tunnels.get(tunnelIdFor(token)).socket;
  const pause = connection.pause.bind(connection);
  let pauses = 0;
  connection.pause = () => { pauses++; return pause(); };
  const incoming = await new Promise((resolve, reject) => {
    const req = http.get({ host: "127.0.0.1", port: httpPort, path: path + "/bulk" }, resolve);
    req.on("error", reject);
    cleanups.push(() => req.destroy());
  });
  await waitFor(() => produced >= 1024 * 1024, { label: "bulk transfer underway" });
  assert.equal((await request(httpPort, path + "/interactive")).status, 200);
  assert.ok(produced < total, "the stalled visitor must backpressure the origin");
  assert.equal(pauses, 0, "only the slow stream should be backpressured");
  let received = 0;
  for await (const data of incoming) received += data.length;
  assert.equal(received, total);
  await waitFor(() => relay.tunnels.get(tunnelIdFor(token)).streams.size === 0, { label: "streams released" });
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




test("a bare address:port never falls back to plain TCP, and says to use tcp://", { timeout: 20000 }, async () => {
  const token = "bare-address-token-0123456789";
  const { agentPort } = await startRelay([token]);
  const plain = [];
  const tunnel = createTunnel({
    url: `127.0.0.1:${agentPort}`,
    token,
    targetPort: () => 9,
    log: { ...quiet, info: (m) => plain.push(String(m)) },
  });
  cleanups.push(() => tunnel.stop());
  await tunnel.start();
  await waitFor(() => tunnel.status().lastError === "relay-not-tls", { label: "relay-not-tls reported", timeoutMs: 8000 });
  // Long enough for the 1 s and 2 s retries: none of them may go out in plain TCP.
  await new Promise((r) => setTimeout(r, 3500));
  assert.notEqual(tunnel.status().status, "online");
  assert.equal(tunnel.status().endpoint, `tls://127.0.0.1:${agentPort}`);
  assert.equal(tunnel.status().lastError, "relay-not-tls");
});

test("a connection error does not linger once the tunnel is online", { timeout: 20000 }, async () => {
  const token = "linger-token-0123456789abcdef";
  const agentPort = await freePort();
  const tunnel = createTunnel({ url: `tcp://127.0.0.1:${agentPort}`, token, targetPort: () => 9, log: quiet });
  cleanups.push(() => tunnel.stop());
  await tunnel.start();
  await waitFor(() => tunnel.status().lastError === "ECONNREFUSED", { label: "first attempt refused" });
  await startRelay([token], { agentPort });
  await waitFor(() => tunnel.status().status === "online", { label: "tunnel online", timeoutMs: 10000 });
  assert.equal(tunnel.status().lastError, null);
});
