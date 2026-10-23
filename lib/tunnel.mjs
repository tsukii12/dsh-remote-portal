/**
 * dsh-remote-portal — outbound tunnel agent.
 *
 * The gateway can only be reached on the LAN. This module lets the same dsh host
 * reach a public relay instead: it dials OUT to `tools/relay.mjs`, keeps one TLS
 * connection open, and answers the streams the relay forwards. Because the
 * connection is outbound, no port forwarding, public IP or NAT traversal is
 * needed on the machine running dsh.
 *
 * It does not re-implement any dsh logic: every stream is proxied to the local
 * gateway (`127.0.0.1:<gatewayPort>`), which is where the password / pairing
 * gate, the cookie minting and the dsh reverse proxy already live. The tunnel is
 * transport, not policy.
 *
 * Frame layout is documented in `tools/relay.mjs` (same file, same constants).
 */
import net from "node:net";
import tls from "node:tls";
import http from "node:http";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const HEADER_BYTES = 9;
const MAX_FRAME_BYTES = 1024 * 1024;

const FRAME = {
  HELLO: 1, WELCOME: 2,
  REQ_HEAD: 3, REQ_BODY: 4, REQ_END: 5,
  RES_HEAD: 6, RES_BODY: 7, RES_END: 8,
  WS_OPEN: 9, WS_DATA: 10, CLOSE: 11, PING: 12, PONG: 13,
};

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

function createFrameReader(onFrame, onError) {
  let buffer = Buffer.alloc(0);
  return function push(chunk) {
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < HEADER_BYTES) return;
      const type = buffer.readUInt8(0);
      const streamId = buffer.readUInt32BE(1);
      const length = buffer.readUInt32BE(5);
      if (length > MAX_FRAME_BYTES) { onError?.(new Error(`frame too large: ${length}`)); return; }
      if (buffer.length < HEADER_BYTES + length) return;
      const payload = buffer.subarray(HEADER_BYTES, HEADER_BYTES + length);
      buffer = buffer.subarray(HEADER_BYTES + length);
      onFrame(type, streamId, payload);
    }
  };
}

function parseJson(buffer) {
  try { return JSON.parse(buffer.toString("utf8")); } catch { return null; }
}

const HOP_BY_HOP = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade", "proxy-connection",
]);

function forwardableHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers || {})) {
    if (value === undefined) continue;
    if (HOP_BY_HOP.has(name.toLowerCase())) continue;
    out[name] = value;
  }
  return out;
}

const RETRY_MS = [1000, 2000, 4000, 8000, 15000, 30000];
const PING_MS = 25000;
const PONG_TIMEOUT_MS = 10000;

/**
 * @param {object} options
 * @param {string} options.url          `tls://relay.example.com:9443` (or `tcp://` for a
 *                                      trusted private network / a local test relay)
 * @param {string} options.token        shared secret; its hash is the tunnel id
 * @param {() => number} options.targetPort  gateway port, read per request (it can change)
 * @param {{info:Function,warn:Function,error:Function}} options.log
 * @param {string} [options.caFile]     PEM bundle for a private CA (optional)
 * @param {boolean} [options.insecure]  skip certificate verification (tests only)
 */
export function createTunnel({ url, token, targetPort, log, caFile, insecure = false }) {
  // Callers may hand us a bare "host:port"; treat that as auto (TLS first).
  const rawUrl = String(url || "").trim();
  const endpoint = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(rawUrl) ? rawUrl : `auto://${rawUrl}`);
  const autoScheme = endpoint.protocol === "auto:";
  const secure = autoScheme || endpoint.protocol === "tls:" || endpoint.protocol === "wss:" || endpoint.protocol === "https:";
  // Which transport the next attempt uses. "auto" starts with TLS and drops to
  // plain TCP once a handshake fails, so the user only supplies address:port.
  let transport = secure ? "tls" : "plain";
  const host = endpoint.hostname;
  const port = Number(endpoint.port) || (secure ? 9443 : 9080);
  const tunnelHint = createHash("sha256").update(String(token)).digest("base64url").slice(0, 12);

  const state = {
    status: "idle",       // idle | connecting | online | retrying | stopped | error
    tunnelId: tunnelHint,
    publicUrl: "",
    connectedAt: 0,
    lastError: null,
    attempts: 0,
    stats: { streams: 0, bytesIn: 0, bytesOut: 0, lastStreamAt: 0 },
  };

  let socket = null;
  let stopped = true;
  let retryTimer = null;
  let pingTimer = null;
  let pongTimer = null;
  const streams = new Map();

  function setStatus(next, error = null) {
    state.status = next;
    if (error !== null) state.lastError = String(error?.message || error);
  }

  function send(type, streamId, payload) {
    if (!socket || socket.destroyed) return false;
    return socket.write(encodeFrame(type, streamId, payload));
  }

  function closeStream(id, reason = "closed") {
    const stream = streams.get(id);
    if (!stream) return;
    streams.delete(id);
    try { stream.cleanup?.(reason); } catch { /* gone */ }
  }

  // ── request handling ─────────────────────────────────────────────────────

  function openHttpStream(id, head) {
    const port = Number(targetPort?.() || 0);
    if (!port) {
      send(FRAME.CLOSE, id, JSON.stringify({ reason: "gateway is not listening" }));
      return;
    }
    const method = String(head.method || "GET").toUpperCase();
    const path = String(head.path || "/");
    const headers = forwardableHeaders(head.headers);

    const upstream = http.request(
      { host: "127.0.0.1", port, method, path, headers },
      (upstreamRes) => {
        const responseHeaders = forwardableHeaders(upstreamRes.headers);
        send(FRAME.RES_HEAD, id, JSON.stringify({ status: upstreamRes.statusCode || 502, headers: responseHeaders }));
        upstreamRes.on("data", (chunk) => {
          state.stats.bytesOut += chunk.length;
          if (!send(FRAME.RES_BODY, id, chunk)) {
            upstreamRes.pause();
            const resume = () => upstreamRes.resume();
            if (socket) socket.once("drain", resume);
            else upstreamRes.resume();
          }
        });
        upstreamRes.on("end", () => {
          send(FRAME.RES_END, id);
          closeStream(id);
        });
        upstreamRes.on("error", () => {
          send(FRAME.CLOSE, id, JSON.stringify({ reason: "upstream error" }));
          closeStream(id);
        });
      },
    );

    upstream.on("error", (error) => {
      send(FRAME.CLOSE, id, JSON.stringify({ reason: `gateway error: ${error?.code || "unknown"}` }));
      closeStream(id);
    });

    streams.set(id, {
      kind: "http",
      request: upstream,
      push: (chunk) => upstream.write(chunk),
      end: () => upstream.end(),
      cleanup: () => { try { upstream.destroy(); } catch { /* gone */ } },
    });
  }

  /**
   * WebSocket upgrade: raw bytes both ways. The gateway owns the handshake, so
   * the only thing this side does is replay the visitor's request head onto a
   * fresh loopback connection and pump.
   */
  function openWsStream(id, message) {
    const port = Number(targetPort?.() || 0);
    if (!port) {
      send(FRAME.CLOSE, id, JSON.stringify({ reason: "gateway is not listening" }));
      return;
    }
    const upstream = net.connect({ host: "127.0.0.1", port });
    upstream.setNoDelay(true);

    upstream.on("connect", () => {
      upstream.write(String(message.head || ""));
      if (message.headB64) {
        const extra = Buffer.from(String(message.headB64), "base64");
        if (extra.length) upstream.write(extra);
      }
    });
    upstream.on("data", (chunk) => {
      state.stats.bytesOut += chunk.length;
      if (!send(FRAME.WS_DATA, id, chunk)) {
        upstream.pause();
        const resume = () => upstream.resume();
        if (socket) socket.once("drain", resume);
        else upstream.resume();
      }
    });
    upstream.on("end", () => { send(FRAME.CLOSE, id, JSON.stringify({ reason: "upstream ended" })); closeStream(id); });
    upstream.on("error", () => { send(FRAME.CLOSE, id, JSON.stringify({ reason: "upstream error" })); closeStream(id); });

    streams.set(id, {
      kind: "ws",
      push: (chunk) => upstream.write(chunk),
      end: () => upstream.end(),
      cleanup: () => { try { upstream.destroy(); } catch { /* gone */ } },
    });
  }

  function dispatch(type, streamId, payload) {
    state.stats.lastStreamAt = Date.now();
    switch (type) {
      case FRAME.REQ_HEAD: {
        const head = parseJson(payload);
        state.stats.streams += 1;
        if (!head) { send(FRAME.CLOSE, streamId, JSON.stringify({ reason: "bad request head" })); return; }
        openHttpStream(streamId, head);
        return;
      }
      case FRAME.REQ_BODY: {
        state.stats.bytesIn += payload.length;
        streams.get(streamId)?.push?.(payload);
        return;
      }
      case FRAME.REQ_END: {
        streams.get(streamId)?.end?.();
        return;
      }
      case FRAME.WS_OPEN: {
        const message = parseJson(payload);
        state.stats.streams += 1;
        if (!message) { send(FRAME.CLOSE, streamId, JSON.stringify({ reason: "bad upgrade" })); return; }
        openWsStream(streamId, message);
        return;
      }
      case FRAME.WS_DATA: {
        state.stats.bytesIn += payload.length;
        streams.get(streamId)?.push?.(payload);
        return;
      }
      case FRAME.CLOSE: closeStream(streamId, "peer closed"); return;
      case FRAME.PONG:
        if (pongTimer) { clearTimeout(pongTimer); pongTimer = null; }
        return;
      case FRAME.PING: send(FRAME.PONG, 0); return;
      default: return;
    }
  }

  // ── connection lifecycle ─────────────────────────────────────────────────

  function connect() {
    if (stopped) return;
    setStatus("connecting");
    state.attempts += 1;

    const options = { host, port, servername: secure ? host : undefined };
    if (caFile) { try { options.ca = readFileSync(caFile); } catch { /* fall back to the system store */ } }
    if (insecure) options.rejectUnauthorized = false;

    const useTls = transport === "tls";
  socket = useTls ? tls.connect(options) : net.connect({ host, port });
    socket.setNoDelay(true);
    socket.setKeepAlive(true, 30000);

    const onOpen = () => {
      send(FRAME.HELLO, 0, JSON.stringify({
        token,
        version: "0.6.0",
        agent: "dsh-remote-portal",
      }));
    };
    if (secure) socket.once("secureConnect", onOpen);
    else socket.once("connect", onOpen);

    const reader = createFrameReader((type, streamId, payload) => {
      if (type === FRAME.WELCOME) {
        const welcome = parseJson(payload);
        if (welcome) {
          state.tunnelId = String(welcome.tunnelId || tunnelHint);
          state.publicUrl = String(welcome.publicUrl || "");
        }
        state.connectedAt = Date.now();
        state.attempts = 0;
        setStatus("online");
        log?.info?.(`tunnel online: ${state.publicUrl || state.tunnelId}`);
        startPing();
        return;
      }
      if (type === FRAME.CLOSE && streamId === 0) {
        const reason = parseJson(payload)?.reason || "closed by relay";
        setStatus("error", reason);
        teardown(reason);
        return;
      }
      dispatch(type, streamId, payload);
    }, (error) => {
      log?.warn?.(`tunnel protocol error: ${error.message}`);
      teardown("protocol error");
    });

    socket.on("data", (chunk) => reader(chunk));
    socket.on("error", (error) => {
      // A failed handshake under "auto" is not an error the user should see: it
      // means the relay speaks plain TCP. Flip once and let the retry succeed.
      if (autoScheme && transport === "tls") {
        transport = "plain";
        log?.info?.("tunnel: no TLS on the relay, retrying in plain TCP");
      }
      state.lastError = String(error?.code || error?.message || error);
      teardown("socket error");
    });
    socket.on("close", () => teardown("closed"));
    socket.on("end", () => teardown("ended"));
  }

  function startPing() {
    stopPing();
    pingTimer = setInterval(() => {
      if (!socket || socket.destroyed) return;
      send(FRAME.PING, 0);
      if (pongTimer) return;
      pongTimer = setTimeout(() => {
        pongTimer = null;
        // A NAT mapping that silently died looks exactly like this; dropping the
        // socket is what makes the reconnect logic notice.
        log?.warn?.("tunnel ping timed out, reconnecting");
        teardown("ping timeout");
      }, PONG_TIMEOUT_MS);
      pongTimer.unref?.();
    }, PING_MS);
    pingTimer.unref?.();
  }

  function stopPing() {
    if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
    if (pongTimer) { clearTimeout(pongTimer); pongTimer = null; }
  }

  function teardown(reason) {
    stopPing();
    if (socket) {
      try { socket.destroy(); } catch { /* gone */ }
      socket = null;
    }
    for (const id of [...streams.keys()]) closeStream(id, reason);
    if (stopped) return;
    const delay = RETRY_MS[Math.min(state.attempts, RETRY_MS.length - 1)];
    setStatus(state.status === "error" ? "error" : "retrying");
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = setTimeout(() => { retryTimer = null; connect(); }, delay);
    retryTimer.unref?.();
    log?.warn?.(`tunnel ${reason}; retrying in ${delay} ms`);
  }

  return {
    async start() {
      if (!stopped) return;
      stopped = false;
      connect();
    },
    async stop() {
      stopped = true;
      if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
      stopPing();
      if (socket) {
        try { socket.destroy(); } catch { /* gone */ }
        socket = null;
      }
      for (const id of [...streams.keys()]) closeStream(id, "stopped");
      setStatus("stopped");
    },
    status() {
      return {
        status: state.status,
        tunnelId: state.tunnelId,
        publicUrl: state.publicUrl,
        connectedAt: state.connectedAt,
        lastError: state.lastError,
        endpoint: `${secure ? "tls" : "tcp"}://${host}:${port}`,
        stats: { ...state.stats },
      };
    },
    /** Used by tests: force a reconnect without waiting for the timer. */
    reconnectNow() {
      if (stopped) return;
      if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
      teardown("manual reconnect");
    },
  };
}

export { FRAME, encodeFrame, createFrameReader };































