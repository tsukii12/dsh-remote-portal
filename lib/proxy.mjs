/**
 * dsh-remote-portal — the reverse proxy half.
 *
 * dsh's web server enforces a **Host/Origin trust fence** (ARCHITECTURE.md §1):
 * `Host` must be loopback (or its own bind literal), an attached `Origin` must
 * name that same authority, and `sec-fetch-site: cross-site` is refused. A phone
 * talking to `http://10.150.23.97:3081` sends `Host: 10.150.23.97:3081`, which
 * dsh would reject — so every forwarded request rewrites `Host`, `Origin` and
 * `Referer` to the upstream authority. That rewrite is the whole reason this
 * module exists; everything else is plumbing.
 *
 * The proxy is *streaming*: request and response bodies are piped, never
 * buffered. That is what carries SSE (`/api/events`-style long-lived responses)
 * and multi-hundred-megabyte workspace downloads through the portal without the
 * gateway growing a memory footprint.
 *
 * WebSocket upgrades cannot go through `http.ServerResponse`, so they are a raw
 * TCP tunnel: connect to the upstream, write the rewritten request line and
 * headers, then pipe both sockets. Whatever the upstream answers (101 or 401)
 * is forwarded verbatim — the browser's WebSocket implementation interprets it.
 */
import http from "node:http";
import https from "node:https";
import net from "node:net";

/** Headers that describe a single hop and must never be forwarded (§3). */
const HOP_BY_HOP = new Set([
  "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
  "te", "trailer", "transfer-encoding", "upgrade", "proxy-connection",
  "http2-settings",
]);

/** Methods the gateway is willing to forward. Anything else is a 405, not a 400. */
const ALLOWED_METHODS = new Set(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]);

const MAX_TARGET_LENGTH = 8192;
/** How long the upstream gets to produce response *headers* before we give up. */
const HEADER_TIMEOUT_MS = 20_000;

// ───────────────────────────────────────────────────────────────────────────
// upstream description
// ───────────────────────────────────────────────────────────────────────────

const DEFAULT_PORTS = { "http:": 80, "https:": 443 };

function normalizeProtocol(value) {
  const raw = String(value ?? "").trim().toLowerCase();
  if (raw === "https" || raw === "https:") return "https:";
  return "http:";
}

/**
 * Describe the dsh web server this process is attached to.
 *
 * Read lazily, on every request: `apply()` can run before the host has finished
 * `listen()`, in which case `webServer.port` is still 0 — and a portal that
 * captures the port once at activation would proxy to `:0` forever.
 *
 * @returns {{ok:boolean, host:string, port:number, protocol:string,
 *            connectHost:string, authority:string, origin:string, reason?:string}}
 */
export function upstreamFromContext(ctx) {
  let webServer = null;
  try {
    webServer = ctx?.webServer ?? null;
  } catch {
    webServer = null;
  }
  const protocol = normalizeProtocol(webServer?.protocol);
  const port = Number(webServer?.port);
  const rawHost = String(webServer?.host ?? "127.0.0.1").trim();
  const host = rawHost === "" ? "127.0.0.1" : rawHost;
  if (!Number.isInteger(port) || port <= 0) {
    return { ok: false, host, port: 0, protocol, connectHost: "", authority: "", origin: "", reason: "upstream-port-unbound" };
  }
  // A wildcard bind is reached over loopback; `localhost` may resolve to ::1
  // first on some Windows boxes, and dsh binds 127.0.0.1, so pin it.
  let connectHost = host.replace(/^\[|\]$/g, "");
  if (connectHost === "0.0.0.0" || connectHost === "::" || connectHost === "*") connectHost = "127.0.0.1";
  if (connectHost === "localhost") connectHost = "127.0.0.1";
  if (connectHost === "::1") connectHost = "::1";
  const defaultPort = DEFAULT_PORTS[protocol];
  const authority = `${connectHost.includes(":") ? `[${connectHost}]` : connectHost}${port === defaultPort ? "" : `:${port}`}`;
  return { ok: true, host, port, protocol, connectHost, authority, origin: `${protocol}//${authority}` };
}

// ───────────────────────────────────────────────────────────────────────────
// request target validation
// ───────────────────────────────────────────────────────────────────────────

const isPortalPath = (pathname) => pathname === "/__portal" || String(pathname).startsWith("/__portal/");

/**
 * Validate a request target before it can reach the upstream.
 *
 * Rejected on purpose:
 *  · absolute-form targets (`GET http://evil/ HTTP/1.1`) — they would make the
 *    gateway an open forward proxy, and are the classic request-smuggling
 *    primitive against a proxy that trusts its peer;
 *  · `*` (asterisk-form) — nothing upstream understands it here;
 *  · control characters and backslashes — header/line injection and Windows
 *    path confusion;
 *  · any `..` segment after percent-decoding, so `/lib/../../secrets` and
 *    `/..%2f..%2f` cannot walk out of the SPA's route space;
 *  · `/__portal/*`, which the gateway owns and must never forward.
 *
 * @returns {{ok:true,path:string,pathname:string,decoded:string,isPortal:boolean}
 *          |{ok:false,status:number,reason:string}}
 */
export function sanitizeTarget(rawUrl, method = "GET") {
  if (!ALLOWED_METHODS.has(String(method || "").toUpperCase())) {
    return { ok: false, status: 405, reason: "method-not-allowed" };
  }
  const target = String(rawUrl ?? "");
  if (target === "") return { ok: false, status: 400, reason: "empty-target" };
  if (target.length > MAX_TARGET_LENGTH) return { ok: false, status: 414, reason: "target-too-long" };
  if (target === "*") return { ok: false, status: 400, reason: "asterisk-form" };
  if (target[0] !== "/") return { ok: false, status: 400, reason: "absolute-form" };
  if (/[\u0000-\u001f\u007f\\]/.test(target)) return { ok: false, status: 400, reason: "control-char" };
  const queryAt = target.indexOf("?");
  const pathname = queryAt === -1 ? target : target.slice(0, queryAt);
  let decoded;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return { ok: false, status: 400, reason: "bad-escape" };
  }
  if (/[\u0000-\u001f\u007f\\]/.test(decoded)) return { ok: false, status: 400, reason: "control-char" };
  if (decoded.split("/").some((segment) => segment === "..")) {
    return { ok: false, status: 403, reason: "path-traversal" };
  }
  return { ok: true, path: target, pathname, decoded, isPortal: isPortalPath(decoded) };
}

// ───────────────────────────────────────────────────────────────────────────
// same-origin guard
// ───────────────────────────────────────────────────────────────────────────

/**
 * Defence in depth for the *outer* listener, mirroring dsh's own fence.
 *
 * The portal cookie is `SameSite=Lax`, which already blocks cross-site POSTs,
 * but Lax still allows top-level GET navigations, and an old browser may not
 * send `Sec-Fetch-Site` at all. An attached `Origin` that names another
 * authority can only come from a cross-site request, so it is refused here
 * before it can reach the (rewritten, therefore trusted) upstream.
 *
 * @returns {{ok:true}|{ok:false,reason:string}}
 */
export function originCheck(req) {
  const headers = req?.headers || {};
  const host = String(headers.host || "").trim().toLowerCase();
  const origin = String(headers.origin || "").trim();
  if (origin !== "" && origin !== "null") {
    let originHost = "";
    try {
      originHost = new URL(origin).host.toLowerCase();
    } catch {
      return { ok: false, reason: "bad-origin" };
    }
    if (host !== "" && originHost !== host) return { ok: false, reason: "origin-mismatch" };
  }
  if (String(headers["sec-fetch-site"] || "").trim().toLowerCase() === "cross-site") {
    return { ok: false, reason: "cross-site" };
  }
  return { ok: true };
}

// ───────────────────────────────────────────────────────────────────────────
// header rewriting
// ───────────────────────────────────────────────────────────────────────────

/** Remove cookies by exact name or by `prefix-` (e.g. `dsh-auth-`). */
export function stripCookies(header, names = []) {
  if (typeof header !== "string" || header === "") return "";
  const drop = (pair) => {
    const name = pair.split("=")[0].trim();
    return names.some((entry) => (entry.endsWith("-") || entry.endsWith("*") ? name.startsWith(entry.replace(/\*$/, "")) : name === entry));
  };
  return header.split(";").map((part) => part.trim()).filter((part) => part !== "" && !drop(part)).join("; ");
}

/** Cookie pairs (`name=value`) out of raw `Set-Cookie` values, for a retry. */
export function cookiePairs(setCookieValues = []) {
  return setCookieValues
    .map((raw) => String(raw || "").split(";")[0].trim())
    .filter((pair) => pair !== "" && pair.includes("="));
}

/** Replace every `dsh-auth-*` cookie with a freshly minted set. */
export function withMintedCookies(header, setCookieValues) {
  const fresh = cookiePairs(setCookieValues);
  const rest = stripCookies(header, ["dsh-auth-"]);
  return [rest, ...fresh].filter(Boolean).join("; ");
}

/**
 * Copy the client's headers and make them acceptable to the upstream fence.
 *
 * @param {object} req                          node request
 * @param {object} opts
 * @param {object} opts.upstream                from upstreamFromContext()
 * @param {string} opts.portalOrigin            origin the client believes it is talking to
 * @param {boolean} [opts.secure]               the portal listener is TLS
 * @param {string} [opts.remoteAddress]         client IP for X-Forwarded-For
 * @param {string} [opts.cookieOverride]        Cookie header to send instead of the client's
 * @param {boolean} [opts.keepUpgrade]          keep Connection/Upgrade (raw tunnel)
 */
export function buildUpstreamHeaders(req, opts) {
  const headers = {};
  for (const [key, value] of Object.entries(req?.headers || {})) {
    if (value === undefined) continue;
    if (HOP_BY_HOP.has(key)) continue;
    headers[key] = value;
  }
  // ── the trust fence ────────────────────────────────────────────────────
  // Host is what dsh authorises against; it must be the loopback authority.
  headers.host = opts.upstream.authority;
  // Origin only ever exists on a same-origin request here (originCheck already
  // refused anything else), so replacing it wholesale is safe and required.
  if (headers.origin !== undefined && headers.origin !== "null") headers.origin = opts.upstream.origin;
  // Referer is informational but dsh may compare it; rewrite the prefix only.
  if (typeof headers.referer === "string" && opts.portalOrigin && headers.referer.startsWith(opts.portalOrigin)) {
    headers.referer = `${opts.upstream.origin}${headers.referer.slice(opts.portalOrigin.length)}`;
  } else if (headers.referer !== undefined) {
    // A referer naming some other site has no business in dsh's logs.
    delete headers.referer;
  }

  // ── forwarding metadata (appended, never trusted for auth) ─────────────
  const remote = String(opts.remoteAddress || "").trim();
  if (remote !== "") {
    const previous = String(headers["x-forwarded-for"] || "").trim();
    headers["x-forwarded-for"] = previous === "" ? remote : `${previous}, ${remote}`;
  }
  headers["x-forwarded-proto"] = opts.secure ? "https" : "http";
  if (req?.headers?.host) headers["x-forwarded-host"] = String(req.headers.host);

  // ── our own session cookie stays on our side of the fence ──────────────
  const cookie = opts.cookieOverride !== undefined && opts.cookieOverride !== null
    ? opts.cookieOverride
    : stripCookies(headers.cookie, ["dsh_portal"]);
  if (cookie) headers.cookie = cookie;
  else delete headers.cookie;

  if (opts.keepUpgrade) {
    headers.connection = "Upgrade";
    const upgrade = String(req?.headers?.upgrade || "websocket");
    headers.upgrade = upgrade;
  }
  return headers;
}

/**
 * Rewrite an absolute `Location` that points at the upstream back to the portal.
 *
 * Without this, the first upstream redirect after login (`Location:
 * http://127.0.0.1:19890/…`) sends the phone to a loopback address it cannot
 * reach. Relative locations are left alone.
 */
export function rewriteLocation(value, { upstream, portalOrigin } = {}) {
  const raw = String(value ?? "");
  if (raw === "" || !/^[a-z][a-z0-9+.-]*:\/\//i.test(raw)) return raw;
  let url;
  try {
    url = new URL(raw);
  } catch {
    return raw;
  }
  if (!upstream || !upstream.authority) return raw;
  const samePort = Number(url.port || DEFAULT_PORTS[url.protocol]) === upstream.port;
  const loopbackish = /^(127\.|localhost$|\[::1\]$|::1$)/i.test(url.hostname);
  if (!(url.host === upstream.authority || (loopbackish && samePort))) return raw;
  let portal;
  try {
    portal = new URL(portalOrigin);
  } catch {
    return raw;
  }
  return `${portal.origin}${url.pathname}${url.search}${url.hash}`;
}

/** Response headers with hop-by-hop removed and Location rewritten. */
export function buildClientHeaders(upstreamHeaders, { upstream, portalOrigin } = {}) {
  const out = {};
  for (const [key, value] of Object.entries(upstreamHeaders || {})) {
    if (HOP_BY_HOP.has(key.toLowerCase())) continue;
    out[key] = value;
  }
  if (out.location !== undefined) {
    out.location = rewriteLocation(out.location, { upstream, portalOrigin });
  }
  return out;
}

// ───────────────────────────────────────────────────────────────────────────
// proxy
// ───────────────────────────────────────────────────────────────────────────

function sendJson(res, status, body, extraHeaders = {}) {
  if (res.headersSent) {
    try { res.end(); } catch { /* gone */ }
    return;
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    ...extraHeaders,
  });
  res.end(payload);
}

/**
 * @param {{log?: {warn:Function}}} [options]
 */
export function createProxy({ log } = {}) {
  const logger = log || { warn() {} };
  // Dedicated agents: keep-alive to loopback saves a TCP handshake per asset
  // (the SPA pulls dozens), and `destroy()` in stop() guarantees no lingering
  // socket keeps the process alive after the plugin is unloaded.
  const httpAgent = new http.Agent({ keepAlive: true, maxSockets: 128, maxFreeSockets: 16, keepAliveMsecs: 15_000 });
  // The upstream is loopback and may present a self-signed certificate; host
  // identity on a loopback socket is not a meaningful check.
  const httpsAgent = new https.Agent({ keepAlive: true, maxSockets: 64, maxFreeSockets: 8, rejectUnauthorized: false });
  const openRequests = new Set();

  function destroy() {
    for (const request of openRequests) {
      try { request.destroy(); } catch { /* gone */ }
    }
    openRequests.clear();
    try { httpAgent.destroy(); } catch { /* gone */ }
    try { httpsAgent.destroy(); } catch { /* gone */ }
  }

  /**
   * Forward one HTTP request.
   *
   * @param {object} req
   * @param {object} res
   * @param {object} opts
   * @param {object} opts.upstream
   * @param {string} opts.path                 validated request target
   * @param {string} opts.portalOrigin
   * @param {boolean} [opts.secure]
   * @param {string} [opts.remoteAddress]
   * @param {string[]} [opts.extraSetCookie]   Set-Cookie values to add to the response
   * @param {(info:{attempt:number,req:object}) => Promise<{retryCookies?:string[],setCookie?:string[],reply?:{status:number,headers?:object,body?:string}}|null>} [opts.onUnauthorized]
   * @param {(status:number) => void} [opts.onUpstreamStatus]
   */
  function request(req, res, opts) {
    const up = opts.upstream;
    if (!up || !up.ok) {
      opts.onUpstreamStatus?.(0);
      sendJson(res, 503, {
        ok: false,
        code: "upstream-unavailable",
        error: "the dsh web server is not listening yet",
      });
      return Promise.resolve();
    }
    const canRetry = (req.method === "GET" || req.method === "HEAD") && typeof opts.onUnauthorized === "function";
    const extraSetCookie = Array.isArray(opts.extraSetCookie) ? opts.extraSetCookie.slice() : [];

    const attempt = (attemptIndex, cookieOverride) => new Promise((resolve) => {
      const headers = buildUpstreamHeaders(req, {
        upstream: up,
        portalOrigin: opts.portalOrigin,
        secure: opts.secure,
        remoteAddress: opts.remoteAddress,
        cookieOverride,
      });
      const mod = up.protocol === "https:" ? https : http;
      let upReq;
      try {
        upReq = mod.request({
          protocol: up.protocol,
          host: up.connectHost,
          port: up.port,
          method: req.method,
          path: opts.path,
          headers,
          agent: up.protocol === "https:" ? httpsAgent : httpAgent,
        });
      } catch (error) {
        logger.warn(`proxy request build failed: ${error?.message || error}`);
        sendJson(res, 502, { ok: false, code: "proxy-error", error: "cannot reach the dsh web server" });
        return resolve({ done: true });
      }
      openRequests.add(upReq);
      let finished = false;
      const settle = (value) => {
        if (finished) return;
        finished = true;
        openRequests.delete(upReq);
        resolve(value);
      };

      upReq.on("error", (error) => {
        opts.onUpstreamStatus?.(0);
        const code = error?.code || error?.name || "error";
        if (res.headersSent) {
          // Mid-stream failure (SSE, big download): the only honest signal left
          // is to drop the connection so the client retries.
          try { res.destroy(); } catch { /* gone */ }
        } else {
          sendJson(res, 502, { ok: false, code: "upstream-error", error: "the dsh web server did not answer", detail: code });
        }
        settle({ done: true, error: code });
      });

      upReq.on("response", (upRes) => {
        upReq.setTimeout(0); // streaming from here on: no idle deadline
        void (async () => {
          opts.onUpstreamStatus?.(Number(upRes.statusCode) || 0);
          if (Number(upRes.statusCode) === 401 && canRetry) {
            upRes.pause(); // do not lose a byte while we decide
            let outcome = null;
            try {
              outcome = await opts.onUnauthorized({ attempt: attemptIndex, req });
            } catch (error) {
              logger.warn(`unauthorized handler failed: ${error?.message || error}`);
              outcome = null;
            }
            if (outcome && outcome.retryCookies && outcome.retryCookies.length > 0 && attemptIndex === 0) {
              upRes.resume(); // drain the discarded 401 body
              const merged = withMintedCookies(req.headers?.cookie, outcome.retryCookies);
              settle({ done: true, retry: { cookies: merged, setCookie: outcome.setCookie || outcome.retryCookies } });
              return;
            }
            if (outcome && outcome.reply) {
              upRes.resume();
              writeReply(res, outcome.reply);
              settle({ done: true, status: outcome.reply.status });
              return;
            }
            upRes.resume();
          }
          writeUpstreamResponse(req, res, upRes, opts, extraSetCookie);
          settle({ done: true, status: Number(upRes.statusCode) || 0 });
        })();
      });

      // Body: streamed, never buffered. `req` ends on its own for GET/HEAD.
      // A retry only ever happens for GET/HEAD (see canRetry), where the request
      // stream is already consumed — piping it a second time would leave the new
      // upstream request un-ended and hang. So the retry just closes it.
      if (attemptIndex === 0) {
        req.pipe(upReq);
      } else {
        upReq.end();
      }
      // Header budget: a dsh process that accepts a connection but never answers
      // must not leave the phone spinning forever. Cleared once the response
      // starts, because SSE legitimately keeps the stream idle for minutes.
      upReq.setTimeout(HEADER_TIMEOUT_MS, () => {
        if (res.headersSent) return;
        sendJson(res, 504, { ok: false, code: "upstream-timeout", error: "the dsh web server did not answer in time" });
        try { upReq.destroy(); } catch { /* gone */ }
        settle({ done: true, error: "upstream-timeout" });
      });
      req.on("error", () => {
        try { upReq.destroy(); } catch { /* gone */ }
        settle({ done: true, error: "client-request-error" });
      });
      res.on("close", () => {
        // Client hung up (tab closed, phone slept): abort the upstream request so
        // the dsh side stops generating tokens for nobody.
        if (!res.writableFinished) {
          try { upReq.destroy(); } catch { /* gone */ }
          settle({ done: true, error: "client-closed" });
        }
      });
    });

    return (async () => {
      const first = await attempt(0, undefined);
      if (first && first.retry) {
        // Hand the freshly minted cookies to the browser on the *retried*
        // response too: the refresh only helps if the jar is updated.
        if (Array.isArray(first.retry.setCookie)) extraSetCookie.push(...first.retry.setCookie);
        await attempt(1, first.retry.cookies);
      }
    })();
  }

  /** Write a substituted reply (login page / JSON) instead of the upstream one. */
  function writeReply(res, reply) {
    const body = Buffer.from(String(reply.body ?? ""), "utf8");
    const headers = {
      "content-type": reply.contentType || "text/html; charset=utf-8",
      "content-length": body.length,
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      ...(reply.headers || {}),
    };
    try {
      res.writeHead(reply.status || 200, headers);
      res.end(body);
    } catch {
      try { res.destroy(); } catch { /* gone */ }
    }
  }

  /** Copy an upstream response to the client, streaming. */
  function writeUpstreamResponse(req, res, upRes, opts, extraSetCookie) {
    const headers = buildClientHeaders(upRes.headers, {
      upstream: opts.upstream,
      portalOrigin: opts.portalOrigin,
    });
    const cookies = [];
    if (headers["set-cookie"] !== undefined) {
      const raw = headers["set-cookie"];
      if (Array.isArray(raw)) cookies.push(...raw);
      else cookies.push(String(raw));
      delete headers["set-cookie"];
    }
    if (extraSetCookie && extraSetCookie.length > 0) cookies.push(...extraSetCookie);
    if (cookies.length > 0) headers["set-cookie"] = cookies;

    try {
      // No Nagle buffering: it costs a few ms per small frame and SSE events
      // arrive as one tiny write each.
      if (req.socket && !req.socket.destroyed) req.socket.setNoDelay(true);
    } catch { /* unsupported */ }

    try {
      res.writeHead(upRes.statusCode || 502, headers);
    } catch (error) {
      logger.warn(`response writeHead failed: ${error?.message || error}`);
      try { res.destroy(); } catch { /* gone */ }
      upRes.destroy();
      return;
    }
    upRes.pipe(res);
    upRes.on("error", () => {
      try { res.destroy(); } catch { /* gone */ }
    });
    res.on("close", () => {
      if (!res.writableFinished) {
        try { upRes.destroy(); } catch { /* gone */ }
      }
    });
  }

  /**
   * Tunnel a WebSocket (or any protocol) upgrade as raw bytes.
   *
   * @param {object} req
   * @param {import("node:net").Socket} socket
   * @param {Buffer} head               bytes the server already read after the headers
   * @param {object} opts               same shape as request(), plus:
   * @param {(socket: import("node:net").Socket) => void} [opts.onSocket]
   */
  function upgrade(req, socket, head, opts) {
    const up = opts.upstream;
    if (!up || !up.ok) {
      writeRawResponse(socket, 503, "upstream unavailable");
      return;
    }
    const headers = buildUpstreamHeaders(req, {
      upstream: up,
      portalOrigin: opts.portalOrigin,
      secure: opts.secure,
      remoteAddress: opts.remoteAddress,
      cookieOverride: opts.cookieOverride,
      keepUpgrade: true,
    });
    const target = net.connect({ host: up.connectHost, port: up.port });
    opts.onSocket?.(target);
    target.setNoDelay(true);
    try { socket.setNoDelay(true); } catch { /* gone */ }
    // A WebSocket can sit idle for hours; never let a socket timeout kill it.
    try { socket.setTimeout(0); } catch { /* gone */ }

    let closed = false;
    const closeBoth = (reason) => {
      if (closed) return;
      closed = true;
      try { target.destroy(); } catch { /* gone */ }
      try { socket.destroy(); } catch { /* gone */ }
      if (reason) logger.warn(`upgrade tunnel closed: ${reason}`);
    };

    let sentHead = false;
    target.on("connect", () => {
      let raw = `${req.method || "GET"} ${opts.path} HTTP/1.1\r\n`;
      for (const [key, value] of Object.entries(headers)) {
        if (Array.isArray(value)) for (const item of value) raw += `${key}: ${item}\r\n`;
        else if (value !== undefined) raw += `${key}: ${value}\r\n`;
      }
      raw += "\r\n";
      try {
        target.write(raw);
        if (head && head.length > 0) target.write(head);
        sentHead = true;
      } catch {
        closeBoth("write failed");
        return;
      }
      target.pipe(socket);
      socket.pipe(target);
    });
    target.on("error", (error) => {
      if (!sentHead) writeRawResponse(socket, 502, "upstream refused the upgrade");
      else closeBoth(`upstream ${error?.code || error?.name || "error"}`);
    });
    socket.on("error", () => closeBoth(""));
    target.on("close", () => {
      if (!closed) closeBoth("");
    });
    socket.on("close", () => {
      if (!closed) closeBoth("");
    });
  }

  function writeRawResponse(socket, status, message) {
    try {
      if (!socket.destroyed && socket.writable) {
        const body = `${message}\n`;
        socket.end(
          `HTTP/1.1 ${status} ${http.STATUS_CODES[status] || "Error"}\r\n` +
          "content-type: text/plain; charset=utf-8\r\n" +
          `content-length: ${Buffer.byteLength(body)}\r\n` +
          "connection: close\r\n\r\n" + body,
        );
      }
    } catch { /* gone */ }
    try { socket.destroy(); } catch { /* gone */ }
  }

  return { request, upgrade, destroy, agents: { httpAgent, httpsAgent } };
}

/**
 * Refuse an upgrade that must not reach the upstream (no session, portal path,
 * hostile target). Done at the raw-socket level because an upgrade has no
 * `ServerResponse` — Node hands us the socket and expects us to speak HTTP.
 */
export function rejectUpgrade(socket, status, message = "") {
  const body = `${message || http.STATUS_CODES[status] || "error"}\n`;
  try {
    if (!socket.destroyed && socket.writable) {
      socket.end(
        `HTTP/1.1 ${status} ${http.STATUS_CODES[status] || "Error"}\r\n` +
        "content-type: text/plain; charset=utf-8\r\n" +
        `content-length: ${Buffer.byteLength(body)}\r\n` +
        "cache-control: no-store\r\n" +
        "connection: close\r\n\r\n" + body,
      );
      return;
    }
  } catch { /* gone */ }
  try { socket.destroy(); } catch { /* gone */ }
}

export { sendJson as sendProxyJson };
