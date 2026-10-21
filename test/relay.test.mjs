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
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { createRelay, tunnelIdFor } from "../tools/relay.mjs";
import { createTunnel } from "../lib/tunnel.mjs";

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




