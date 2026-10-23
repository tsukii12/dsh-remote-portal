#!/usr/bin/env node
/**
 * dsh-remote-portal relay — a small, dependency-free reverse tunnel server.
 *
 *   home machine                          public server
 *  ┌───────────────────┐   outbound TLS   ┌────────────────────────┐
 *  │ dsh + portal      │ ───────────────▶ │ relay.mjs              │
 *  │  gateway :3081    │   one multiplexed│  :9443  agent port     │
 *  │  tunnel  ─────────┼── socket ───────▶│  :8080  visitor port   │◀── phone / laptop
 *  └───────────────────┘                  └────────────────────────┘
 *
 * The agent (the dsh host) dials *out*, so the home network needs no port
 * forwarding, no public IP and no NAT traversal. Visitors only ever see this
 * server. Each browser connection is forwarded to the agent as a stream; the
 * agent answers by proxying to its loopback gateway, which is what applies the
 * password / pairing gate. The relay deliberately knows nothing about dsh: it
 * is a tunnel with a routing prefix.
 *
 * Why one multiplexed socket and not one connection per request: a page load is
 * ~75 requests, and a TLS handshake per request over the public internet costs
 * far more than the framing does. Streams are cheap; handshakes are not.
 *
 * Wire format (both directions, little-endian):
 *
 *     0        type        uint8
 *     1..4     streamId    uint32
 *     5..8     length      uint32
 *     9..      payload     `length` bytes
 *
 * Types are listed in FRAME below. Control frames (HELLO/WELCOME/PING/PONG) use
 * stream 0 and a JSON payload; request/response bodies and WebSocket bytes are
 * raw payload, so a tunnel never base64-encodes user traffic.
 *
 * Usage:
 *   node tools/relay.mjs --token-file .relay-token --agent-port 9443 \
 *        --http-port 8080 --public-url https://dsh.example.com
 *
 * See docs/DEPLOY-SERVER.md for a systemd unit, a Caddy front and a Dockerfile.
 */
import http from "node:http";
import https from "node:https";
import tls from "node:tls";
import net from "node:net";
import { createHash, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// ───────────────────────────────────────────────────────────────────────────
// framing
// ───────────────────────────────────────────────────────────────────────────

/** Printed at startup and by --version, so an installed copy is identifiable. */
const RELAY_VERSION = "0.6.1";

const FRAME = {
  HELLO: 1,
  WELCOME: 2,
  REQ_HEAD: 3,
  REQ_BODY: 4,
  REQ_END: 5,
  RES_HEAD: 6,
  RES_BODY: 7,
  RES_END: 8,
  WS_OPEN: 9,
  WS_DATA: 10,
  CLOSE: 11,
  PING: 12,
  PONG: 13,
};

const HEADER_BYTES = 9;
const MAX_FRAME_BYTES = 1024 * 1024; // 1 MiB per frame; bodies are chunked by the parser

function encodeFrame(type, streamId, payload) {
  const body = payload === undefined ? Buffer.alloc(0)
    : Buffer.isBuffer(payload) ? payload
      : Buffer.from(String(payload), "utf8");
  const head = Buffer.allocUnsafe(HEADER_BYTES);
  head.writeUInt8(type, 0);
  head.writeUInt32BE(streamId >>> 0, 1);
  head.writeUInt32BE(body.length, 5);
  return body.length === 0 ? head : Buffer.concat([head, body], HEADER_BYTES + body.length);
}

/**
 * Incremental frame reader. A socket hands us arbitrary chunks; this keeps the
 * remainder between calls and yields complete frames. A frame larger than
 * MAX_FRAME_BYTES is a protocol error, not something to buffer forever.
 */
function createFrameReader(onFrame, onError) {
  let buffer = Buffer.alloc(0);
  return function push(chunk) {
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < HEADER_BYTES) return;
      const type = buffer.readUInt8(0);
      const streamId = buffer.readUInt32BE(1);
      const length = buffer.readUInt32BE(5);
      if (length > MAX_FRAME_BYTES) {
        const error = new Error(`frame too large: ${length}`);
        // 0x16 is a TLS handshake record: worth naming, since the usual cause is
        // a tls:// endpoint pointed at a plaintext port.
        error.firstByte = type;
        onError?.(error);
        return;
      }
      if (buffer.length < HEADER_BYTES + length) return;
      const payload = buffer.subarray(HEADER_BYTES, HEADER_BYTES + length);
      buffer = buffer.subarray(HEADER_BYTES + length);
      onFrame(type, streamId, payload);
    }
  };
}

function json(payload) {
  try {
    return JSON.parse(payload.toString("utf8"));
  } catch {
    return null;
  }
}

/** Tunnel ids are derived from the token so they are stable across restarts. */
/**
 * Host the public URL points at, used in operator-facing hints.
 * Derived from --public-url so the message matches what the docs print.
 */
function hostOfPublicUrl(value) {
  try {
    return new URL(String(value)).hostname || "this-server";
  } catch {
    return "this-server";
  }
}

function tunnelIdFor(token) {
  return createHash("sha256").update(String(token)).digest("base64url").slice(0, 12);
}

function sameSecret(a, b) {
  const left = createHash("sha256").update(String(a)).digest();
  const right = createHash("sha256").update(String(b)).digest();
  return timingSafeEqual(left, right);
}

// ───────────────────────────────────────────────────────────────────────────
// configuration
// ───────────────────────────────────────────────────────────────────────────

/**
 * Parse "port" or "host:port" (also `[::1]:port`).
 *
 * Returns { port, host } with host undefined when the flag carried no address.
 * Throws on nonsense: a mistyped bind must be loud, never silently defaulted.
 */
function parseBind(value, label) {
  const raw = String(value ?? "").trim();
  if (raw === "") return { port: undefined, host: undefined };
  const v6 = /^\[([^\]]+)\]:(\d+)$/.exec(raw);
  const pair = v6 ? [raw, v6[1], v6[2]] : /^([^:]+):(\d+)$/.exec(raw);
  if (pair) {
    const port = Number(pair[2]);
    if (!Number.isInteger(port) || port < 0 || port > 65535) {
      throw new Error(`${label}: invalid port in "${raw}"`);
    }
    return { port, host: pair[1] };
  }
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`${label}: expected a port or host:port, got "${raw}"`);
  }
  return { port, host: undefined };
}

function parseArgs(argv) {
  const out = { tokens: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    const take = () => (next !== undefined && !next.startsWith("--") ? (i++, next) : true);
    switch (key) {
      case "token": out.tokens.push(String(take())); break;
      case "token-file": out.tokenFile = String(take()); break;
      case "agent-port": out.agentPort = String(take()); break;
      case "agent-host": out.agentHost = String(take()); break;
      case "http-port": out.httpPort = String(take()); break;
      case "http-host": out.httpHost = String(take()); break;
      case "tls-host": out.tlsHost = String(take()); break;
      case "tls-port": out.tlsPort = String(take()); break;
      case "tls-cert": out.tlsCert = String(take()); break;
      case "tls-key": out.tlsKey = String(take()); break;
      case "public-url": out.publicUrl = String(take()); break;
      case "prefix": out.prefix = String(take()); break;
      case "max-streams": out.maxStreams = Number(take()); break;
      case "request-timeout": out.requestTimeout = Number(take()); break;
      case "version": out.version = true; break;
      case "help": out.help = true; break;
      default: break;
    }
  }
  return out;
}

const USAGE = `
dsh-remote-portal relay

  --agent-port <p>       port the dsh host dials OUT to; "port" or "host:port"
                         (TLS when --tls-cert is set)        (default 0.0.0.0:9443)
  --agent-host <addr>    bind address when the flag carries a bare port
  --http-port <p>        visitor port, plain HTTP; "port" or "host:port"
                         (default 127.0.0.1:8080 — loopback unless you say otherwise)
  --tls-port <p>         visitor port, direct HTTPS; "port" or "host:port" (optional)
  --tls-host <addr>      bind address for that port when the flag carries a bare port
  --tls-cert/--tls-key   PEM files used by both TLS listeners
  --token <secret>       one tunnel token (repeatable)
  --token-file <path>    file with one token per line ("#" comments allowed)
  --public-url <url>     how visitors reach this relay, e.g. https://dsh.example.com
  --prefix <path>        routing prefix                     (default /__t)
  --max-streams <n>      concurrent streams per tunnel      (default 256)
  --request-timeout <ms> upstream timeout                   (default 120000)
  --help

Put this behind Caddy/nginx on 443 for certificates (see docs/DEPLOY-SERVER.md),
or pass --tls-port with a certificate for a direct HTTPS listener.
`;

// ───────────────────────────────────────────────────────────────────────────
// relay
// ───────────────────────────────────────────────────────────────────────────

const log = {
  info: (msg) => console.log(`[relay] ${msg}`),
  warn: (msg) => console.warn(`[relay] ${msg}`),
  error: (msg) => console.error(`[relay] ${msg}`),
};

/** Security headers for pages the relay itself renders (not proxied content). */
const LOCAL_HEADERS = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "x-frame-options": "DENY",
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'",
};

function sendPlain(res, status, text, extra = {}) {
  const body = Buffer.from(String(text), "utf8");
  res.writeHead(status, {
    ...LOCAL_HEADERS,
    "content-type": "text/plain; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
    ...extra,
  });
  res.end(body);
}

function sendPage(res, status, title, message) {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
:root{color-scheme:light dark}
body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;
background:#0f1115;color:#f9fafb;padding:24px}
.card{max-width:420px;padding:28px 30px;border-radius:14px;background:#1b1b1c;border:1px solid #ffffff1f}
h1{margin:0 0 8px;font-size:17px}p{margin:0;color:#cfd3d6}
code{font:12px ui-monospace,Menlo,monospace;color:#adb2b8}
@media (prefers-color-scheme:light){body{background:#f9fafb;color:#0f1115}.card{background:#fff;border-color:#0000001a}p{color:#61666b}code{color:#81858c}}
</style></head><body><div class="card"><h1>${title}</h1><p>${message}</p></div></body></html>`;
  const body = Buffer.from(html, "utf8");
  res.writeHead(status, {
    ...LOCAL_HEADERS,
    "content-type": "text/html; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  res.end(body);
}

/** Hop-by-hop headers must not be forwarded through a proxy hop. */
const HOP_BY_HOP = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade", "proxy-connection",
]);

function forwardableHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers)) {
    if (value === undefined) continue;
    if (HOP_BY_HOP.has(name.toLowerCase())) continue;
    out[name] = value;
  }
  return out;
}

function createRelay(config) {
  /** tunnelId → tunnel state */
  const tunnels = new Map();
  const startedAt = Date.now();
  // "visitors" used to count every request that reached this listener probe included,
// which reads like a head count and is not one. Requests and distinct clients are
// counted separately now.
const stats = { requests: 0, streams: 0, bytesIn: 0, bytesOut: 0, rejected: 0, cacheHits: 0, cacheStored: 0 };
const seenClients = new Map(); // address -> first seen, capped
const SEEN_CLIENT_LIMIT = 5000;

// Static assets dominate a first load of the harness UI, and every byte of them
// otherwise travels from the operator's uplink through this process. Hashed asset
// URLs never change, so keep them here: a reload then costs nothing on the home side.
const ASSET_CACHE = new Map(); // key -> { at, status, headers, body }
let assetCacheBytes = 0;
const CACHE_MAX_BYTES = Number(process.env.DSH_RELAY_CACHE_MB) > 0
  ? Number(process.env.DSH_RELAY_CACHE_MB) * 1024 * 1024
  : 128 * 1024 * 1024;
const CACHE_MAX_OBJECT = 16 * 1024 * 1024;
const CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const CACHEABLE_TYPE = /^(text\/css|text\/javascript|application\/javascript|application\/json|font\/|image\/|application\/font)/i;

/** Hashed build output is immutable; anything else may carry per-session data. */
function isCacheableAsset(pathname) {
  if (!pathname.includes("/assets/")) return false;
  return /\.(?:js|mjs|css|woff2?|ttf|otf|eot|png|jpe?g|gif|svg|webp|ico|map)$/i.test(pathname);
}

/** The origin decides; a no-store answer or Vary: cookie is not ours to keep. */
function responseAllowsCache(headers, status) {
  if (status !== 200) return false;
  if (headers["set-cookie"]) return false;
  const cc = String(headers["cache-control"] || "");
  if (/no-store|private/i.test(cc)) return false;
  const vary = String(headers["vary"] || "");
  if (vary.includes("*") || /cookie/i.test(vary)) return false;
  return CACHEABLE_TYPE.test(String(headers["content-type"] || ""));
}

/** index-a1b2c3d4.js / vendor.9f8e7d6c.css: the name changes when the content does. */
function isImmutableName(pathname) {
  return /[.\-][0-9a-f]{8,}(?:\.[0-9a-f]{2,})?\.(?:js|mjs|css|woff2?|ttf|otf|png|jpe?g|gif|svg|webp|ico)$/i.test(pathname);
}

function cacheGet(key) {
  const hit = ASSET_CACHE.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at > CACHE_TTL_MS) {
    ASSET_CACHE.delete(key);
    assetCacheBytes -= hit.body.length;
    return null;
  }
  ASSET_CACHE.delete(key);
  ASSET_CACHE.set(key, hit); // refresh recency
  return hit;
}

function cachePut(key, entry) {
  const existing = ASSET_CACHE.get(key);
  if (existing) assetCacheBytes -= existing.body.length;
  ASSET_CACHE.set(key, entry);
  assetCacheBytes += entry.body.length;
  stats.cacheStored = (stats.cacheStored || 0) + 1;
  while (assetCacheBytes > CACHE_MAX_BYTES && ASSET_CACHE.size > 1) {
    const oldest = ASSET_CACHE.keys().next().value;
    const gone = ASSET_CACHE.get(oldest);
    ASSET_CACHE.delete(oldest);
    if (gone) assetCacheBytes -= gone.body.length;
  }
}

  for (const token of config.tokens) {
    const id = tunnelIdFor(token);
    tunnels.set(id, {
      id,
      token,
      socket: null,
      agent: null,
      streams: new Map(),
      connectedAt: 0,
      lastSeenAt: 0,
      stats: { streams: 0, bytes: 0 },
    });
  }

  // ── agent side ───────────────────────────────────────────────────────────

  /**
   * One agent connection = one tunnel. The first frame must be HELLO with a
   * token we know; everything after that is stream traffic for that tunnel id.
   */
  function handleAgent(socket, peer) {
    socket.setNoDelay(true);
    socket.setKeepAlive(true, 30000);
    let tunnel = null;
    let alive = true;

    const close = (reason) => {
      if (!alive) return;
      alive = false;
      if (tunnel && tunnel.socket === socket) {
        tunnel.socket = null;
        tunnel.connectedAt = 0;
        tunnel.lastSeenAt = 0;
        tunnel.lastDropReason = String(reason || "unknown");
        tunnel.lastDropAt = Date.now();
        tunnel.reconnects = (tunnel.reconnects || 0) + 1;
        for (const stream of tunnel.streams.values()) {
          try { stream.fail(502, "tunnel disconnected"); } catch { /* gone */ }
        }
        tunnel.streams.clear();
        log.warn(`tunnel ${tunnel.id} disconnected (${reason})`);
      }
      try { socket.destroy(); } catch { /* gone */ }
    };

    const send = (type, streamId, payload) => {
      if (!alive || socket.destroyed) return false;
      return socket.write(encodeFrame(type, streamId, payload));
    };

    const publicHost = hostOfPublicUrl(config.publicUrl);
    const reader = createFrameReader((type, streamId, payload) => {
      // `tunnel` is null until HELLO authenticates, so it must not be touched
      // before that branch — doing so used to throw inside the socket handler.
      if (tunnel) tunnel.lastSeenAt = Date.now();
      if (!tunnel) {
        if (type !== FRAME.HELLO) { close("expected HELLO"); return; }
        const hello = json(payload);
        if (!hello || typeof hello.token !== "string") { close("bad HELLO"); return; }
        const id = tunnelIdFor(hello.token);
        const candidate = tunnels.get(id);
        if (!candidate || !sameSecret(candidate.token, hello.token)) {
          stats.rejected += 1;
          send(FRAME.CLOSE, 0, JSON.stringify({ reason: "unauthorized" }));
          log.warn(`rejected agent from ${peer} (unknown token)`);
          setTimeout(() => close("unauthorized"), 30);
          return;
        }
        tunnel = candidate;
        if (tunnel.socket && tunnel.socket !== socket) {
          // A second agent for the same token replaces the first: the old one is
          // almost certainly a half-dead connection after a network change.
          try { tunnel.socket.destroy(); } catch { /* gone */ }
          tunnel.reconnects = (tunnel.reconnects || 0) + 1;
          tunnel.lastDropReason = "replaced by a new connection";
          tunnel.lastDropAt = Date.now();
        }
        tunnel.socket = socket;
        tunnel.agent = { version: String(hello.version || ""), peer };
        tunnel.connectedAt = Date.now();
        tunnel.lastSeenAt = Date.now();
        const publicPath = publicPathFor(tunnel.id);
        send(FRAME.WELCOME, 0, JSON.stringify({
          tunnelId: tunnel.id,
          publicPath,
          publicUrl: `${config.publicUrl.replace(/\/$/, "")}${publicPath}/`,
          limits: { maxStreams: config.maxStreams, requestTimeout: config.requestTimeout },
        }));
        log.info(`tunnel ${tunnel.id} connected from ${peer}`);
        return;
      }
      dispatchFromAgent(tunnel, type, streamId, payload);
    }, (error) => {
      // 0x16 = TLS handshake record type. This port is plain TCP unless the
      // relay was started with a certificate, so the fix is on the client side:
      // the dsh panel must use tcp:// here, not tls://.
      // Wrong *protocol* on this port is by far the most common setup mistake, and
      // the raw error ("frame too large: <garbage>") points at the wrong layer.
      // Two shapes cover it: a TLS ClientHello (0x16), and an HTTP request line
      // (a middlebox or a proxy rewriting the connection).
      const first = error && Number.isInteger(error.firstByte) ? error.firstByte : -1;
      if (first === 0x16) {
        log.warn(
          `agent from ${socket.remoteAddress || "?"} sent a TLS ClientHello, but this port serves plain TCP.` +
            ` Use tcp://${publicHost}:${config.agentPort} in the panel, or start the relay with --tls-cert/--tls-key.`
        );
      } else if (first >= 0x41 && first <= 0x5a) {
        log.warn(
          `agent from ${socket.remoteAddress || "?"} sent what looks like an HTTP request on the agent port` +
            ` (first byte 0x${first.toString(16)}). Something between the host and this port is rewriting the` +
            ` connection; the agent must be able to open a raw TCP stream to ${config.agentPort}.`
        );
      } else {
        log.warn(`agent protocol error: ${error.message}`);
      }
      close("protocol error");
    });

    socket.on("data", (chunk) => { stats.bytesIn += chunk.length; reader(chunk); });
    socket.on("error", () => close("socket error"));
    socket.on("close", () => close("closed"));
    socket.on("end", () => close("ended"));
  }

  /** Frames coming *from* the agent answer a stream the relay opened. */
  function dispatchFromAgent(tunnel, type, streamId, payload) {
    // Keepalive lives on stream 0 and must be answered here: an unanswered PING
    // makes the agent believe the public link died and reconnect every ~35 s,
    // which shows up as random 502s on whatever request happens to be in flight.
    if (type === FRAME.PING) {
      try { tunnel.socket?.write(encodeFrame(FRAME.PONG, 0)); } catch { /* gone */ }
      return;
    }
    if (type === FRAME.PONG) return;
    const stream = tunnel.streams.get(streamId);
    if (!stream) return;
    try {
      switch (type) {
        case FRAME.RES_HEAD: {
          const head = json(payload);
          if (!head) { stream.fail(502, "bad response head"); return; }
          stream.onHead(head);
          break;
        }
        case FRAME.RES_BODY: stream.onBody(payload); break;
        case FRAME.RES_END: stream.onEnd(); break;
        case FRAME.WS_DATA: stream.onBody(payload); break;
        case FRAME.CLOSE: stream.fail(502, json(payload)?.reason || "closed"); break;
        default: break;
      }
    } catch (error) {
      log.warn(`stream ${streamId} failed: ${error?.message || error}`);
      try { stream.fail(502, "stream error"); } catch { /* gone */ }
    }
  }

  // ── visitor side ─────────────────────────────────────────────────────────

  function publicPathFor(id) {
    return `${config.prefix}/${id}`;
  }

  /** Resolve `/__t/<id>/…` to a tunnel + the path the agent should see. */
  function routeFor(pathname) {
    const prefix = `${config.prefix}/`;
    if (!pathname.startsWith(prefix)) return null;
    const rest = pathname.slice(prefix.length);
    const slash = rest.indexOf("/");
    const id = slash === -1 ? rest : rest.slice(0, slash);
    const tail = slash === -1 ? "/" : rest.slice(slash);
    const tunnel = tunnels.get(id);
    if (!tunnel) return { tunnel: null, id, path: tail };
    return { tunnel, id, path: tail };
  }

  function openStream(tunnel, handlers) {
    if (!tunnel.socket || tunnel.socket.destroyed) {
      handlers.fail(503, "the dsh host is not connected to the relay");
      return null;
    }
    if (tunnel.streams.size >= config.maxStreams) {
      handlers.fail(503, "too many concurrent streams");
      return null;
    }
    let id = 1;
    while (tunnel.streams.has(id)) id += 1;
    const stream = {
      id,
      onHead: handlers.onHead,
      onBody: handlers.onBody,
      onEnd: handlers.onEnd,
      fail: handlers.fail,
      closed: false,
    };
    tunnel.streams.set(id, stream);
    tunnel.stats.streams += 1;
    stats.streams += 1;
    const timer = setTimeout(() => {
      if (!stream.closed) handlers.fail(504, "the dsh host did not answer in time");
    }, config.requestTimeout);
    timer.unref?.();
    const release = () => {
      if (stream.closed) return;
      stream.closed = true;
      try { clearTimeout(timer); } catch { /* ignore */ }
      tunnel.streams.delete(id);
    };
    stream.release = release;
    return { id, send: (type, payload) => tunnel.socket?.write(encodeFrame(type, id, payload)), release };
  }

  function handleVisitor(req, res) {
    const url = new URL(req.url || "/", `http://${req.headers.host || "relay"}`);
    // Internal probes are this tool talking to itself; they are not traffic.
    const internal = url.pathname === "/__relay/health" || url.pathname === "/healthz";
    if (!internal) {
      stats.requests += 1;
      const who = (req.socket && req.socket.remoteAddress) || "unknown";
      if (!seenClients.has(who) && seenClients.size < SEEN_CLIENT_LIMIT) {
        seenClients.set(who, Date.now());
      }
    }

    if (url.pathname === "/__relay/health" || url.pathname === "/healthz") {
      const body = Buffer.from(JSON.stringify({
        ok: true,
        uptimeMs: Date.now() - startedAt,
        tunnels: [...tunnels.values()].map((t) => ({
          id: t.id,
          connected: Boolean(t.socket),
          streams: t.streams.size,
          since: t.connectedAt,
          reconnects: t.reconnects || 0,
          lastDropReason: t.lastDropReason || "",
          lastDropAt: t.lastDropAt || 0,
          agentVersion: t.agent?.version || "",
          requests: stats.requests,
          clients: seenClients.size,
        })),
        stats,
      }), "utf8");
      res.writeHead(200, {
        ...LOCAL_HEADERS,
        "content-type": "application/json; charset=utf-8",
        "content-length": body.length,
        "cache-control": "no-store",
      });
      res.end(body);
      return;
    }

    if (url.pathname === "/" || url.pathname === "") {
      sendPage(res, 200, "dsh remote portal relay",
        `This is a <code>dsh-remote-portal</code> relay. Open the private link your Harness gave you: <code>${config.prefix}/&lt;tunnel&gt;/</code>`);
      return;
    }

    // A tunnel URL without its trailing slash breaks every relative link on the
    // page (the browser resolves them against the parent directory), so the
    // login form would POST to /__t/__portal/login and the relay would read
    // "__portal" as a tunnel id. Redirect once instead of asking people to
    // remember the slash.
    const bare = `${config.prefix}/`;
    if (url.pathname.startsWith(bare)) {
      const rest = url.pathname.slice(bare.length);
      if (rest !== "" && !rest.includes("/") && tunnels.has(rest)) {
        res.writeHead(301, {
          ...LOCAL_HEADERS,
          location: `${bare}${rest}/${url.search}`.replace(/\?$/, ""),
          "content-length": 0,
          "cache-control": "no-store",
        });
        res.end();
        return;
      }
    }

    const route = routeFor(url.pathname);
    if (!route) {
      sendPage(res, 404, "Not found", "This relay only serves tunnel links.");
      return;
    }
    if (!route.tunnel) {
      sendPage(res, 404, "Unknown tunnel", `No tunnel named <code>${route.id}</code> is registered here.`);
      return;
    }
    if (!route.tunnel.socket || route.tunnel.socket.destroyed) {
      sendPage(res, 503, "The host is offline",
        "The dsh machine is not connected to the relay right now. Start dsh (or turn the portal back on) and this page will work again — the link itself does not change.");
      return;
    }

    const target = route.path + (url.search || "");
    const cacheKey = req.method === "GET" && isCacheableAsset(url.pathname)
      ? route.id + "\u0000" + target
      : "";
    let cached = null;
    if (cacheKey) {
      const hit = cacheGet(cacheKey);
      if (hit) {
        const inm = req.headers["if-none-match"];
        if (inm && hit.headers.etag && inm === hit.headers.etag) {
          stats.cacheHits += 1;
          res.writeHead(304, { ...hit.headers, "content-length": 0 });
          res.end();
          return;
        }
        // Hashed names are immutable: no round trip at all.
        if (isImmutableName(url.pathname)) {
          stats.cacheHits += 1;
          res.writeHead(hit.status, { ...hit.headers, "x-drp-cache": "hit" });
          res.end(hit.body);
          return;
        }
        // Otherwise serve the stored copy only once the origin confirms it.
        if (hit.headers.etag) cached = hit;
        else {
          stats.cacheHits += 1;
          res.writeHead(hit.status, { ...hit.headers, "x-drp-cache": "hit" });
          res.end(hit.body);
          return;
        }
      }
    }

    const headers = forwardableHeaders(req.headers);
    // The agent's gateway rewrites Host/Origin for the upstream; what it needs
    // here is the *public* authority so its own same-origin check passes.
    const upstreamHeaders = { ...headers, "x-forwarded-proto": config.publicUrl.startsWith("https") ? "https" : "http" };
    // Revalidate instead of re-downloading.
    if (cached && cached.headers.etag) upstreamHeaders["if-none-match"] = cached.headers.etag;
    if (!upstreamHeaders["x-forwarded-for"]) upstreamHeaders["x-forwarded-for"] = clientIp(req);
    // The app is mounted under this prefix; it needs it to build correct
    // redirects and form actions (the relay strips the prefix before proxying).
    upstreamHeaders["x-forwarded-prefix"] = publicPathFor(route.id);

    let headSent = false;
    // A cacheable response is streamed to the visitor and copied on the side; the
    // copy is only kept when the whole thing arrived and looks safe to reuse.
    let cacheBuffer = null;
    const stream = openStream(route.tunnel, {
      onHead: (head) => {
        headSent = true;
        const status = Number(head.status) || 502;
        if (cached && status === 304) {
          stats.cacheHits += 1;
          res.writeHead(cached.status, { ...cached.headers, "x-drp-cache": "revalidated" });
          res.end(cached.body);
          return;
        }
        const responseHeaders = forwardableHeaders(head.headers || {});
        if (cacheKey && responseAllowsCache(head.headers || {}, status)) {
          cacheBuffer = { status, headers: responseHeaders, chunks: [], size: 0 };
        }
        // Keep the browser's cache semantics but never let the relay host's own
        // headers leak into a tunnel response.
        res.writeHead(Number(head.status) || 502, responseHeaders);
      },
      onBody: (chunk) => {
        stats.bytesOut += chunk.length;
        if (cacheBuffer) {
          cacheBuffer.size += chunk.length;
          if (cacheBuffer.size > CACHE_MAX_OBJECT) cacheBuffer = null;
          else cacheBuffer.chunks.push(chunk);
        }
        if (!res.write(chunk)) {
          // Backpressure: stop pulling from the tunnel until the socket drains.
          route.tunnel.socket.pause();
          res.once("drain", () => route.tunnel.socket.resume());
        }
      },
      onEnd: () => {
        try { res.end(); } catch { /* gone */ }
        if (cacheBuffer) {
          cachePut(cacheKey, {
            at: Date.now(),
            status: cacheBuffer.status,
            headers: cacheBuffer.headers,
            body: Buffer.concat(cacheBuffer.chunks),
          });
        }
        stream?.release?.();
      },
      fail: (status, reason) => {
        if (!headSent && !res.headersSent) sendPage(res, status, "Tunnel error", String(reason));
        else try { res.end(); } catch { /* gone */ }
        stream?.release?.();
      },
    });
    if (!stream) return;

    stream.send(FRAME.REQ_HEAD, JSON.stringify({
      method: req.method,
      path: target,
      headers: upstreamHeaders,
    }));

    req.on("data", (chunk) => {
      stats.bytesIn += chunk.length;
      stream.send(FRAME.REQ_BODY, chunk);
    });
    req.on("end", () => stream.send(FRAME.REQ_END));
    req.on("error", () => stream.release());
    res.on("close", () => {
      if (!res.writableEnded) {
        stream.send(FRAME.CLOSE, JSON.stringify({ reason: "client closed" }));
        stream.release();
      }
    });
  }

  /**
   * WebSocket upgrade through the tunnel.
   *
   * The relay cannot re-create the handshake (that is dsh's business), so it
   * forwards the raw request line + headers and then pipes bytes both ways. The
   * agent connects a TCP socket to its loopback gateway and replays the same
   * handshake, so the gateway sees a normal upgrade from a same-origin client.
   */
  function handleUpgrade(req, socket, head) {
    const url = new URL(req.url || "/", `http://${req.headers.host || "relay"}`);
    const route = routeFor(url.pathname);
    if (!route || !route.tunnel || !route.tunnel.socket) {
      socket.write("HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
      socket.destroy();
      return;
    }

    const stream = openStream(route.tunnel, {
      onHead: (headMsg) => { /* unused for ws streams */ },
      onBody: (chunk) => {
        stats.bytesOut += chunk.length;
        if (!socket.write(chunk)) {
          route.tunnel.socket.pause();
          socket.once("drain", () => route.tunnel.socket.resume());
        }
      },
      onEnd: () => { try { socket.end(); } catch { /* gone */ } },
      fail: () => { try { socket.destroy(); } catch { /* gone */ } },
    });
    if (!stream) return;

    const lines = [`${req.method} ${route.path + (url.search || "")} HTTP/1.1`];
    for (const [name, value] of Object.entries(req.headers)) {
      if (Array.isArray(value)) for (const one of value) lines.push(`${name}: ${one}`);
      else lines.push(`${name}: ${value}`);
    }
    stream.send(FRAME.WS_OPEN, JSON.stringify({
      head: lines.join("\r\n") + "\r\n\r\n",
      headB64: head && head.length ? head.toString("base64") : "",
    }));

    socket.setNoDelay(true);
    socket.on("data", (chunk) => {
      stats.bytesIn += chunk.length;
      stream.send(FRAME.WS_DATA, chunk);
    });
    socket.on("close", () => {
      stream.send(FRAME.CLOSE, JSON.stringify({ reason: "client closed" }));
      stream.release();
    });
    socket.on("error", () => { try { socket.destroy(); } catch { /* gone */ } });
  }

  // ── listeners ────────────────────────────────────────────────────────────

  const visitors = http.createServer(handleVisitor);
  visitors.on("upgrade", handleUpgrade);
  visitors.on("clientError", (_error, socket) => {
    try { socket.end("HTTP/1.1 400 Bad Request\r\n\r\n"); } catch { /* gone */ }
  });

  let visitorTls = null;
  if (config.tlsPort && config.tlsCert && config.tlsKey) {
    visitorTls = https.createServer(loadTls(), handleVisitor);
    visitorTls.on("upgrade", handleUpgrade);
  }

  const agentServer = config.tlsCert && config.tlsKey
    ? tls.createServer(loadTls(), handleAgent)
    : net.createServer(handleAgent);

  function loadTls() {
    return {
      cert: readFileSync(config.tlsCert),
      key: readFileSync(config.tlsKey),
      minVersion: "TLSv1.2",
    };
  }

  function listen(server, port, host) {
    return new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, host, () => {
        server.removeListener("error", reject);
        resolve(server.address());
      });
    });
  }

  return {
    stats,
    tunnels,
    async start() {
      const agentAddr = await listen(agentServer, config.agentPort, config.agentHost);
      const visitorAddr = await listen(visitors, config.httpPort, config.httpHost);
      let tlsAddr = null;
      if (visitorTls) tlsAddr = await listen(visitorTls, config.tlsPort, config.tlsHost || config.httpHost);
      log.info(`relay  v${RELAY_VERSION}`);
  log.info(`agent  ${config.tlsCert ? "tls" : "tcp"} ${config.agentHost}:${agentAddr.port}`);
      log.info(`visitor http  ${config.httpHost}:${visitorAddr.port}`);
      if (tlsAddr) log.info(`visitor https ${config.tlsHost || config.httpHost}:${tlsAddr.port}`);
      for (const tunnel of tunnels.values()) {
        log.info(`tunnel ${tunnel.id} → ${config.publicUrl.replace(/\/$/, "")}${publicPathFor(tunnel.id)}/`);
      }
      return { agentPort: agentAddr.port, httpPort: visitorAddr.port, tlsPort: tlsAddr?.port || 0 };
    },
    async stop() {
      // Live tunnels first: an open agent socket holds the listening server's
      // close() pending forever, which is why a restart used to hang until
      // systemd gave up and killed the process.
      for (const tunnel of tunnels.values()) {
        try { tunnel.socket?.destroy(); } catch { /* gone */ }
        tunnel.socket = null;
      }
      const close = (server) => new Promise((resolve) => {
        if (!server) return resolve();
        try { server.closeAllConnections?.(); } catch { /* http only */ }
        try { server.close(() => resolve()); } catch { resolve(); }
        // Whatever still clings to a socket must not block the shutdown.
        const t = setTimeout(resolve, 2000);
        t.unref?.();
      });
      await Promise.all([close(agentServer), close(visitors), close(visitorTls)]);
    },
  };
}

function clientIp(req) {
  const direct = req.socket?.remoteAddress || "";
  const forwarded = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
  return forwarded || direct.replace(/^::ffff:/, "");
}

// ───────────────────────────────────────────────────────────────────────────
// main
// ───────────────────────────────────────────────────────────────────────────

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.version) {
    process.stdout.write(RELAY_VERSION + "\n");
    return;
  }
  if (args.help) {
    console.log(USAGE);
    return;
  }
  if (args.tokenFile) {
    const text = readFileSync(args.tokenFile, "utf8");
    for (const line of text.split(/\r?\n/)) {
      const value = line.trim();
      if (value === "" || value.startsWith("#")) continue;
      args.tokens.push(value);
    }
  }
  const agentBind = parseBind(args.agentPort, "--agent-port");
  const visitorHttp = parseBind(args.httpPort, "--http-port");
  const visitorHttps = parseBind(args.tlsPort, "--tls-port");
  const config = {
    tokens: args.tokens.filter(Boolean),
    agentPort: agentBind.port === undefined ? 9443 : agentBind.port,
    agentHost: agentBind.host || args.agentHost || "0.0.0.0",
    httpPort: visitorHttp.port === undefined ? 8080 : visitorHttp.port,
    httpHost: visitorHttp.host || args.httpHost || "127.0.0.1",
    tlsPort: visitorHttps.port === undefined ? 0 : visitorHttps.port,
    tlsHost: visitorHttps.host || args.tlsHost || "",
    tlsCert: args.tlsCert || "",
    tlsKey: args.tlsKey || "",
    publicUrl: args.publicUrl || `http://localhost:${Number.isInteger(args.httpPort) ? args.httpPort : 8080}`,
    prefix: (args.prefix || "/__t").replace(/\/$/, ""),
    maxStreams: Number.isInteger(args.maxStreams) ? args.maxStreams : 256,
    requestTimeout: Number.isInteger(args.requestTimeout) ? args.requestTimeout : 120000,
  };
  if (config.tokens.length === 0) {
    console.error("relay: at least one --token or --token-file is required\n" + USAGE);
    process.exit(2);
  }
  if (Boolean(config.tlsCert) !== Boolean(config.tlsKey)) {
    console.error("relay: --tls-cert and --tls-key must be given together");
    process.exit(2);
  }

  const relay = createRelay(config);
  relay.start().catch((error) => {
    log.error(`failed to start: ${error?.message || error}`);
    process.exit(1);
  });

  const shutdown = (signal) => {
    log.info(`${signal} received, closing…`);
    const hard = setTimeout(() => process.exit(0), 5000);
    hard.unref?.();
    relay.stop().then(() => process.exit(0), () => process.exit(1));
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === join(dirname(process.argv[1]), "relay.mjs");
if (isMain) main();

export { createRelay, tunnelIdFor, encodeFrame, createFrameReader, FRAME, parseArgs };


