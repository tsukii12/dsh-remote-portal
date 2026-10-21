/**
 * dsh-remote-portal — the gateway Portal object (ARCHITECTURE.md §4.1).
 *
 * One `node:http` listener that is the only thing a phone talks to:
 *
 *   socket → rate limit → /__portal/* internal → handle
 *                       → /dsh-remote-portal/assets/* → serve from disk
 *                       → portal session valid? no → login page / 401
 *                                              yes → authenticated reverse proxy
 *
 * The portal owns its own authentication (password or one-time pairing code)
 * and, after a successful login, mints a *dsh* browser cookie on the user's
 * behalf (lib/mint.mjs) so the proxied SPA is already authorised. That last step
 * is what makes remote access work at all — see §1 of the architecture.
 *
 * Lifecycle contract that the panel depends on:
 *   · `start()` rejects on `needs-password` / `EADDRINUSE` and records why;
 *   · `applyConfig()` never throws for a bind failure — it returns a Status with
 *     `lastError` set so the Settings panel can show it;
 *   · `stop()` is idempotent, works when never started, and resolves only after
 *     the listener and every socket (including upgraded ones) are gone.
 */
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { createReadStream, readFileSync, statSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";

import { StateStore, defaultStateDir } from "./state.mjs";
import {
  Lockout, MIN_PASSWORD_LENGTH, PORTAL_COOKIE, clearCookie, expireCookie, hashPassword,
  hashToken, issueSession, mintPairToken, parseCookies, safeEqual, sessionCookie,
  verifyPassword, verifySessionCookie,
} from "./auth.mjs";
import {
  assertBindSafe, discoverAddresses, discoverAddressesSync, isLoopback, isWildcard,
  urlsFor,
} from "./net.mjs";
import {
  createProxy, originCheck, rejectUpgrade, sanitizeTarget, upstreamFromContext,
  withMintedCookies,
} from "./proxy.mjs";
import { createMinter, sanitizeSetCookie } from "./mint.mjs";
import { createTunnel } from "./tunnel.mjs";

export const PLUGIN_NAME = "dsh-remote-portal";
export const PORTAL_PREFIX = "/__portal";
export const ASSET_PREFIX = "/dsh-remote-portal/assets/";
export const QR_PATH = "/dsh-remote-portal/qr.svg";
/** Requests per IP per 10 s; generous enough for a cold SPA load (~60 assets). */
export const RATE_WINDOW_MS = 10_000;

export const DEFAULT_CONFIG = {
  enabled: true,
  host: "0.0.0.0",
  port: 3081,
  stateDir: null,
  mobile: true,
  tls: null,
  // Public relay: `{ url: "tls://relay.example.com:9443", token, caFile?, insecure? }`.
  // Off by default — a LAN portal must never start dialing a third party because
  // it happened to be installed.
  tunnel: null,
  auth: { mode: "password", sessionDays: 30, maxFailures: 5, lockSeconds: 60 },
  rateLimit: 1200,
  brand: "DeepSeek Harness",
  lang: null,
};

const ASSET_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".svg", "image/svg+xml; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".webmanifest", "application/manifest+json; charset=utf-8"],
  [".png", "image/png"],
  [".webp", "image/webp"],
  [".woff2", "font/woff2"],
  [".ico", "image/x-icon"],
]);

const LOGIN_PAGE_FILE = "./login-page.mjs";
const QR_FILE = "./qr.mjs";
/** qr.mjs tops out at version 10 / ECC-M = 213 UTF-8 bytes; above that it throws. */
const QR_MAX_BYTES = 213;
const LOCAL_MODULE_RETRY_MS = 30_000;
const BODY_LIMIT = 16 * 1024;
const PROBE_TIMEOUT_MS = 800;

// ───────────────────────────────────────────────────────────────────────────
// helpers
// ───────────────────────────────────────────────────────────────────────────

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const clamp = (value, min, max, fallback) => {
  const n = Number(value);
  return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : fallback;
};
const text = (error) => String(error?.message || error || "unknown error");

function errorWith(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

/** Bound logger that never throws and never receives a secret. */
function makeLogger(log, ctx) {
  const prefix = `${PLUGIN_NAME}:`;
  const pick = (level) => (message) => {
    try {
      if (log && typeof log[level] === "function") return log[level](String(message));
      const host = ctx?.logger;
      if (host && typeof host[level] === "function") return host[level](`${prefix} ${message}`);
      if (level === "info") return undefined;
      return console.warn(`${prefix} ${message}`);
    } catch {
      return undefined;
    }
  };
  return { info: pick("info"), warn: pick("warn"), error: pick("error") };
}

// ───────────────────────────────────────────────────────────────────────────
// config
// ───────────────────────────────────────────────────────────────────────────

function normalizeTls(value) {
  if (!isObject(value)) return null;
  const certFile = typeof value.certFile === "string" ? value.certFile.trim() : "";
  const keyFile = typeof value.keyFile === "string" ? value.keyFile.trim() : "";
  return certFile && keyFile ? { certFile, keyFile } : null;
}

/**
 * Public tunnel config.
 *
 * `url` is `tls://relay.example.com:9443`; `token` is the shared secret whose
 * hash names the tunnel. The token is persisted (it has to be) but it never
 * leaves the host: `status()`/`config()` report only its presence and the
 * derived tunnel id.
 */
function normalizeTunnel(value) {
  if (!isObject(value)) return null;
  const url = typeof value.url === "string" ? value.url.trim() : "";
  const token = typeof value.token === "string" ? value.token.trim() : "";
  if (url === "" || token === "") return null;
  let protocol = "";
  try { protocol = new URL(url).protocol; } catch { return null; }
  if (!["tls:", "tcp:", "wss:", "https:"].includes(protocol)) return null;
  const caFile = typeof value.caFile === "string" && value.caFile.trim() !== "" ? value.caFile.trim() : "";
  return { url, token, caFile, insecure: value.insecure === true };
}

/**
 * Validate one config object against a base.
 *
 * Used twice: on construction (entry config over DEFAULT_CONFIG) and by
 * `applyConfig` (the patch over the current config, where an absent key means
 * "keep what you have" rather than "reset to default"). Keeping one function for
 * both is what stops the panel's partial POST from silently dropping `tls`.
 */
export function normalizeConfig(source = {}, base = DEFAULT_CONFIG) {
  const src = isObject(source) ? source : {};
  const authSrc = isObject(src.auth) ? src.auth : {};
  const authBase = base.auth || DEFAULT_CONFIG.auth;
  const has = (key) => Object.prototype.hasOwnProperty.call(src, key);
  const mode = has("auth") && ["password", "pair-only", "open"].includes(authSrc.mode) ? authSrc.mode : authBase.mode;
  return {
    enabled: has("enabled") && typeof src.enabled === "boolean" ? src.enabled : base.enabled,
    host: has("host") && typeof src.host === "string" && src.host.trim() !== "" ? src.host.trim() : base.host,
    port: has("port") ? clamp(src.port, 0, 65535, base.port) : base.port,
    stateDir: has("stateDir") && typeof src.stateDir === "string" ? src.stateDir : base.stateDir,
    mobile: has("mobile") && typeof src.mobile === "boolean" ? src.mobile : base.mobile,
    tls: has("tls") ? normalizeTls(src.tls) : base.tls,
    tunnel: has("tunnel") ? normalizeTunnel(src.tunnel) : (base.tunnel ?? null),
    auth: {
      mode: ["password", "pair-only", "open"].includes(mode) ? mode : "password",
      sessionDays: has("auth") ? clamp(authSrc.sessionDays, 1, 365, authBase.sessionDays) : authBase.sessionDays,
      maxFailures: has("auth") ? clamp(authSrc.maxFailures, 1, 50, authBase.maxFailures) : authBase.maxFailures,
      lockSeconds: has("auth") ? clamp(authSrc.lockSeconds, 5, 3600, authBase.lockSeconds) : authBase.lockSeconds,
    },
    rateLimit: has("rateLimit") ? clamp(src.rateLimit, 0, 100_000, base.rateLimit) : base.rateLimit,
    brand: has("brand") && typeof src.brand === "string" && src.brand.trim() !== "" ? src.brand.trim() : base.brand,
    lang: has("lang") && (src.lang === "zh" || src.lang === "en") ? src.lang : base.lang,
  };
}

/** Only the keys the panel may persist; everything else is entry-config only. */
function pickOverrides(patch) {
  const out = {};
  if (!isObject(patch)) return out;
  // An explicit `undefined` means "not supplied" — persisting it would read as a
  // value downstream and silently turn `enabled` off on an unrelated save.
  const sent = (key) => Object.prototype.hasOwnProperty.call(patch, key) && patch[key] !== undefined;
  for (const key of ["enabled", "host", "port", "mobile", "tls", "tunnel"]) {
    if (sent(key)) out[key] = patch[key];
  }
  if (isObject(patch.auth)) {
    const authPatch = {};
    for (const key of ["mode", "sessionDays", "maxFailures", "lockSeconds"]) {
      if (Object.prototype.hasOwnProperty.call(patch.auth, key) && patch.auth[key] !== undefined) {
        authPatch[key] = patch.auth[key];
      }
    }
    if (Object.keys(authPatch).length > 0) out.auth = authPatch;
  }
  return out;
}

// ───────────────────────────────────────────────────────────────────────────
// small HTTP helpers
// ───────────────────────────────────────────────────────────────────────────

/**
 * Headers every response this gateway produces carries.
 *
 * The portal's own pages are the only place in the product where a stranger on
 * the network gets HTML with an authentication form in it, so they are locked
 * down harder than the app behind them:
 *
 *   frame-ancestors / XFO   the login form must not be framed by another site
 *                           (clickjacking a password field is the obvious attack
 *                           on a product like this);
 *   COOP same-origin        a framed or popup-opened page cannot keep a handle
 *                           on our window object;
 *   CORP same-origin        our QR/asset responses cannot be embedded elsewhere;
 *   Permissions-Policy      nothing here needs camera, mic, location or topics;
 *   no-referrer             a pair link must never leak through a Referer.
 *
 * Proxied upstream responses are deliberately NOT touched: the app behind the
 * gate is dsh's business, and rewriting its headers could break it.
 */
const SECURITY_HEADERS = {
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "cross-origin-opener-policy": "same-origin",
  "cross-origin-resource-policy": "same-origin",
  "permissions-policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; " +
    "img-src 'self' data:; font-src 'self'; connect-src 'self'; form-action 'self'; " +
    "base-uri 'none'; frame-ancestors 'none'",
};

function sendJson(res, status, body, headers = {}) {
  if (res.headersSent) {
    try { res.end(); } catch { /* gone */ }
    return;
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
    ...headers,
  });
  res.end(payload);
}

function sendText(res, status, body, type = "text/plain; charset=utf-8", headers = {}) {
  if (res.headersSent) {
    try { res.end(); } catch { /* gone */ }
    return;
  }
  const payload = Buffer.from(String(body), "utf8");
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    "content-type": type,
    "content-length": payload.length,
    "cache-control": "no-store",
    ...headers,
  });
  res.end(payload);
}

function sendHtml(res, status, html, headers = {}) {
  sendText(res, status, html, "text/html; charset=utf-8", {
    // The login page must never be cached: it contains the locked/error state
    // and, in pair mode, a one-time button.
    "cache-control": "no-store, max-age=0",
    ...headers,
  });
}

/** 303 with an arbitrary set of Set-Cookie values. */
function sendRedirect(res, location, cookies = [], extraHeaders = {}) {
  const headers = {
    ...SECURITY_HEADERS,
    location,
    "cache-control": "no-store",
    "content-length": 0,
    ...extraHeaders,
  };
  const list = cookies.filter(Boolean);
  if (list.length > 0) headers["set-cookie"] = list;
  res.writeHead(303, headers);
  res.end();
}

function readBody(req, limit = BODY_LIMIT, timeoutMs = 10_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const settle = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) rejectPromise(error);
      else resolvePromise(value);
    };
    const timer = setTimeout(() => {
      settle(errorWith("body-timeout", "request body timed out"));
      try { req.destroy(); } catch { /* gone */ }
    }, timeoutMs);
    timer.unref?.();
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        settle(errorWith("body-too-large", "request body is too large"));
        try { req.destroy(); } catch { /* gone */ }
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => settle(null, Buffer.concat(chunks)));
    req.on("error", (error) => settle(error));
  });
}

function parseLoginBody(buffer, contentType) {
  const raw = buffer.toString("utf8");
  if (String(contentType || "").toLowerCase().includes("application/json")) {
    try {
      const value = JSON.parse(raw);
      return isObject(value) ? value : {};
    } catch {
      return {};
    }
  }
  const params = new URLSearchParams(raw);
  return {
    password: params.get("password") ?? "",
    token: params.get("token") ?? "",
    pairToken: params.get("pairToken") ?? "",
    next: params.get("next") ?? "",
  };
}

/** Only ever redirect to a same-origin path; an open redirect here is a phishing 303. */
/**
 * Where this request is mounted, when something is proxying us.
 *
 * The relay strips its prefix before forwarding, so `/` here is the tunnel root,
 * not the site root. Without this every redirect we emit would point outside the
 * prefix and land on the relay's own 404.
 */
function mountPrefix(req) {
  const raw = String(req?.headers?.["x-forwarded-prefix"] ?? "").trim();
  if (raw === "" || !raw.startsWith("/") || raw.includes("..") || /[\u0000-\u001f]/.test(raw)) return "";
  return raw.replace(/\/+$/, "");
}

/** Prefix an app-absolute path with the mount prefix (identity when there is none). */
function withMount(req, path) {
  const base = mountPrefix(req);
  const target = String(path || "/");
  if (base === "") return target;
  return target === "/" ? `${base}/` : `${base}${target.startsWith("/") ? "" : "/"}${target}`;
}

function safeNext(value) {
  // Always absolute. A relative target ("." or "./") is resolved by the browser
  // against the *request* URI, so a redirect from /__portal/pair or
  // /__portal/login lands on /__portal/ — which is not the app.
  const fallback = "/";
  const raw = String(value ?? "").trim();
  if (raw === "") return fallback;
  if (!raw.startsWith("/") || raw.startsWith("//") || raw.startsWith("/\\")) return fallback;
  if (raw.startsWith(PORTAL_PREFIX)) return fallback;
  if (/[\u0000-\u001f\u007f\\]/.test(raw)) return fallback;
  return raw.slice(0, 2048);
}

function pathLabel(rawUrl) {
  const value = String(rawUrl ?? "").split("?")[0].split("#")[0];
  return value === "" ? "/" : value.slice(0, 300);
}

/** "Looks like the browser is navigating to a page" (as opposed to XHR/fetch). */
function wantsHtml(req) {
  const dest = String(req.headers?.["sec-fetch-dest"] || "").toLowerCase();
  if (dest === "document" || dest === "iframe" || dest === "frame") return true;
  const accept = String(req.headers?.accept || "");
  if (/text\/html/i.test(accept)) return true;
  const path = pathLabel(req.url);
  if (path === "/" || path === "/index.html" || /\.html?$/i.test(path)) {
    return !/application\/json/i.test(accept) && !/text\/event-stream/i.test(accept);
  }
  return false;
}

function clientIp(req) {
  const raw = String(req?.socket?.remoteAddress || "").trim();
  const plain = raw.toLowerCase().startsWith("::ffff:") ? raw.slice(7) : raw;
  return plain === "" ? "unknown" : plain;
}

function hasDshCookie(req) {
  const cookies = parseCookies(req?.headers?.cookie);
  return Object.keys(cookies).some((name) => name.toLowerCase().startsWith("dsh-auth-"));
}

/** "iPhone · Safari" — enough for the device list to be recognisable. */
function deviceLabel(userAgent) {
  const ua = String(userAgent || "");
  if (ua === "") return "unknown device";
  const platform =
    /iPhone/i.test(ua) ? "iPhone" :
    /iPad/i.test(ua) ? "iPad" :
    /Android/i.test(ua) ? "Android" :
    /Windows/i.test(ua) ? "Windows" :
    /Macintosh|Mac OS X/i.test(ua) ? "macOS" :
    /Linux/i.test(ua) ? "Linux" :
    // Scripted clients have no OS token; without this they would be listed as a
    // bare "device", which reads like a bug in the device list.
    /curl|Wget|PowerShell|python-requests|node-fetch|Go-http-client/i.test(ua) ? "CLI" : "device";
  const browser =
    /Edg\//i.test(ua) ? "Edge" :
    /OPR\//i.test(ua) ? "Opera" :
    /Firefox\//i.test(ua) ? "Firefox" :
    /Chrome\//i.test(ua) ? "Chrome" :
    /Safari\//i.test(ua) ? "Safari" : "";
  return browser ? `${platform} · ${browser}` : platform;
}

// ───────────────────────────────────────────────────────────────────────────
// gateway
// ───────────────────────────────────────────────────────────────────────────

/**
 * @param {object} options
 * @param {object} options.ctx              cordis context (real or test double)
 * @param {object} [options.config]         entry config (ARCHITECTURE.md §5)
 * @param {string} [options.stateDir]       override; defaults to <DSH_HOME>/dsh-remote-portal
 * @param {object} [options.log]            { info, warn, error }
 * @param {string} [options.pluginDir]      absolute plugin directory (assets live here)
 * @param {string} [options.pluginVersion]  version string exposed as `portal.version`
 */
export function createGateway({ ctx, config, stateDir, log, pluginDir, pluginVersion } = {}) {
  const logger = makeLogger(log, ctx);
  const dir = String(stateDir || config?.stateDir || defaultStateDir()).trim() || defaultStateDir();
  const store = new StateStore({ dir, log: logger });
  const state = store.load();
  const version = String(pluginVersion || readOwnVersion() || "0.0.0");
  const pluginRoot = pluginDir && String(pluginDir).trim() !== ""
    ? resolve(String(pluginDir))
    : fileURLToPath(new URL("../", import.meta.url));
  const assetsDir = join(pluginRoot, "assets");

  let cfg = normalizeConfig(config || {});
  // Runtime changes made in the panel win over the entry config, so a toggle
  // survives a restart instead of being resurrected by cordis.patch.yml (§5).
  cfg = normalizeConfig({ ...cfg, ...state.overrides, auth: { ...cfg.auth, ...(state.overrides.auth || {}) } });

  const lockout = new Lockout({
    maxFailures: cfg.auth.maxFailures,
    baseLockMs: cfg.auth.lockSeconds * 1000,
  });
  const proxy = createProxy({ log: logger });
  const minter = createMinter({ ctx, log: logger });
  const localModules = new Map();

  const rt = {
    server: null,
    sockets: new Set(),
    running: false,
    state: cfg.enabled ? "stopped" : "disabled",
    startedAt: 0,
    boundHost: "",
    boundPort: 0,
    protocol: cfg.tls ? "https:" : "http:",
    lastError: null,
    addresses: [],
    upstreamReachable: null,
    dshSession: "unknown",
    rate: new Map(),
    flushTimer: null,
    accessDirty: false,
    // Public relay state (see startTunnel/stopTunnel).
    tunnel: null,
    tunnelSignature: "",
  };

  // ── access log + counters ────────────────────────────────────────────────

  function scheduleFlush() {
    rt.accessDirty = true;
    if (rt.flushTimer) return;
    rt.flushTimer = setTimeout(() => {
      rt.flushTimer = null;
      flushState();
    }, 5000);
    rt.flushTimer.unref?.(); // never keep the host process alive for a log flush
  }

  function flushState() {
    if (!rt.accessDirty) return;
    rt.accessDirty = false;
    lockout.prune();
    store.prune();
    store.save();
  }

  /**
   * Static assets are noise in a human-facing access log: one page load brings a
   * dozen JS/CSS/font requests and would push the interesting rows (a login, a
   * navigation, an API call) out of the card within two refreshes. They still
   * count toward the request counter; they just do not get a log row.
   */
  function isAssetNoise(pathname) {
    const path = String(pathname || "");
    if (/^\/(?:assets|plugins)\//.test(path)) return true;
    return /\.(?:js|mjs|css|map|woff2?|ttf|otf|svg|png|jpe?g|webp|gif|ico)(?:\?|$)/i.test(path);
  }

  function recordAccess({ ip, req, status, startedAt, auth, ua, bytes = 0 }) {
    state.counters.requests += 1;
    state.counters.lastRequestAt = Date.now();
    if (Number.isFinite(bytes) && bytes > 0) state.counters.bytesOut += bytes;
    const rawPath = String(req.url || "/");
    if (isAssetNoise(pathLabel(rawPath))) {
      scheduleFlush();
      return;
    }
    store.appendAccess({
      at: Date.now(),
      ip,
      method: String(req.method || "GET").slice(0, 10),
      path: pathLabel(req.url),
      status: Number(status) || 0,
      ms: Math.max(0, Date.now() - startedAt),
      auth,
      ua: String(ua || "").slice(0, 120),
    });
    scheduleFlush();
  }

  // ── upstream / status helpers ────────────────────────────────────────────

  function upstreamDescriptor() {
    return { ...upstreamFromContext(ctx), portalVersion: version };
  }

  function addresses() {
    return rt.addresses.length > 0 ? rt.addresses : discoverAddressesSync();
  }

  function currentUrls() {
    return urlsFor({
      bindHost: rt.boundHost || cfg.host,
      port: rt.boundPort || cfg.port,
      protocol: rt.protocol,
      addresses: addresses(),
    });
  }

  function isSecure() {
    return rt.protocol === "https:";
  }

  /**
   * The "your LAN address is …" hint on the login page.
   *
   * It only makes sense when the visitor is actually on that LAN: through a
   * relay the request arrives on the public host, and showing a 192.168.x.x
   * address there is noise at best and misleading at worst.
   */
  function lanHint(req) {
    const host = String(req?.headers?.host || "").toLowerCase();
    if (host === "") return "";
    const hostname = host.startsWith("[") ? host.slice(1, host.indexOf("]")) : host.split(":")[0];
    const local = new Set(["127.0.0.1", "::1", "localhost"]);
    for (const entry of addresses()) {
      if (entry && entry.address) local.add(String(entry.address).toLowerCase());
    }
    if (!local.has(hostname)) return "";
    const { lanUrls } = currentUrls();
    const first = lanUrls[0];
    if (!first) return "";
    try {
      return new URL(first).host;
    } catch {
      return "";
    }
  }

  function pairingActive(now = Date.now()) {
    return Object.values(state.pairing).some((entry) => entry.expiresAt > now && !entry.usedAt);
  }

  /** Descriptor for the client's own origin (Host header), used for Location rewrites. */
  function portalOriginFor(req) {
    const host = String(req?.headers?.host || "").trim();
    const scheme = isSecure() ? "https:" : "http:";
    if (host !== "" && /^[A-Za-z0-9._\-:[\]]+$/.test(host)) return `${scheme}//${host}`;
    const first = currentUrls().urls[0];
    if (first) {
      try { return new URL(first).origin; } catch { /* fall through */ }
    }
    return `${scheme}//127.0.0.1:${rt.boundPort || cfg.port}`;
  }

  function requestLang(req) {
    if (cfg.lang) return cfg.lang;
    const accept = String(req?.headers?.["accept-language"] || "");
    return /^zh/i.test(accept.trim()) || /\bzh/i.test(accept) ? "zh" : "en";
  }

  async function probeUpstream({ timeoutMs = PROBE_TIMEOUT_MS } = {}) {
    const up = upstreamFromContext(ctx);
    if (!up.ok) {
      rt.upstreamReachable = false;
      return false;
    }
    return new Promise((resolvePromise) => {
      let settled = false;
      const socket = net.connect({ host: up.connectHost, port: up.port });
      const finish = (ok) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { socket.destroy(); } catch { /* gone */ }
        rt.upstreamReachable = ok;
        resolvePromise(ok);
      };
      const timer = setTimeout(() => finish(false), timeoutMs);
      timer.unref?.();
      socket.once("connect", () => finish(true));
      socket.once("error", () => finish(false));
    });
  }

  // ── lazy local modules (login page / QR may land after the gateway starts) ─

  async function loadLocalModule(relative, exportName) {
    const cached = localModules.get(relative);
    const now = Date.now();
    if (cached && cached.module) return cached.module;
    if (cached && now - cached.triedAt < LOCAL_MODULE_RETRY_MS) return null;
    const entry = { module: null, triedAt: now, noted: cached ? cached.noted : false };
    localModules.set(relative, entry);
    const href = new URL(relative, import.meta.url);
    try {
      // stat first: a failed dynamic import is cached by the ESM loader, so a
      // module that does not exist yet would stay "missing" for this process.
      const stat = statSync(fileURLToPath(href));
      // Cache-buster keyed on mtime: a module that is replaced on disk is picked
      // up without restarting dsh.
      const module = await import(`${href.href}?v=${Math.round(stat.mtimeMs)}`);
      if (module && typeof module[exportName] === "function") {
        entry.module = module;
        localModules.set(relative, entry);
        return module;
      }
      if (!entry.noted) {
        entry.noted = true;
        logger.warn(`${relative} does not export ${exportName}()`);
      }
      return null;
    } catch (error) {
      if (!entry.noted) {
        entry.noted = true;
        logger.info(`${relative} not usable yet (${error?.code || error?.name || "error"}); using the built-in fallback`);
      }
      return null;
    }
  }

  /** Render the login page, preferring auth-page's implementation when present. */
  async function renderLogin(overrides = {}) {
    const opts = {
      lang: overrides.lang || cfg.lang || "en",
      brand: cfg.brand,
      mode: "password",
      next: "./",
      lanHint: lanHint(overrides.req),
      version,
      ...overrides,
    };
    if (opts.lang !== "zh" && opts.lang !== "en") opts.lang = "en";
    const module = await loadLocalModule(LOGIN_PAGE_FILE, "renderLoginPage");
    if (module) {
      try {
        const html = module.renderLoginPage(opts);
        if (typeof html === "string" && html.trim() !== "") return html;
      } catch (error) {
        logger.warn(`renderLoginPage threw: ${text(error)}`);
      }
    }
    return fallbackLoginPage(opts);
  }

  // ── cookie minting ───────────────────────────────────────────────────────

  async function mintForClient({ force = false } = {}) {
    const up = upstreamDescriptor();
    if (!up.ok) {
      rt.dshSession = "unavailable";
      return [];
    }
    let cookies = [];
    try {
      cookies = await minter.mint(up, { force });
    } catch (error) {
      logger.warn(`cookie mint failed: ${text(error)}`);
      cookies = [];
    }
    rt.dshSession = minter.state().status;
    return cookies;
  }

  /** Full Set-Cookie values, made safe for this listener (drops Secure over http). */
  function cookiesForClient(values) {
    return (values || []).map((raw) => sanitizeSetCookie(raw, { secure: isSecure() })).filter(Boolean);
  }

  // ── sessions ────────────────────────────────────────────────────────────

  function sessionFor(req, ip) {
    const cookies = parseCookies(req?.headers?.cookie);
    const raw = cookies[PORTAL_COOKIE];
    if (!raw) return { kind: "none" };
    const now = Date.now();
    const verified = verifySessionCookie(raw, {
      secret: state.secret,
      ua: req.headers["user-agent"],
      now,
    });
    if (!verified.ok) return { kind: "invalid", reason: verified.reason };
    const session = state.sessions[verified.id];
    if (!session || !(session.expiresAt > now)) {
      delete state.sessions[verified.id];
      return { kind: "invalid", reason: "unknown-session" };
    }
    session.lastSeenAt = now;
    const device = session.deviceId ? state.devices[session.deviceId] : null;
    if (device) {
      device.lastSeenAt = now;
      if (ip) device.ip = ip;
    }
    return { kind: "session", session, device };
  }

  /**
   * @returns {{ok:true, auth:string, session?:object, device?:object}
   *          |{ok:false, reason:string}}
   */
  function authorize(req, ip) {
    if (cfg.auth.mode === "open") {
      // assertBindSafe() guarantees this only ever happens on loopback.
      if (!isLoopback(rt.boundHost || cfg.host)) return { ok: false, reason: "open-mode-not-loopback" };
      return { ok: true, auth: "open" };
    }
    const found = sessionFor(req, ip);
    if (found.kind === "session") return { ok: true, auth: "session", session: found.session, device: found.device };
    return { ok: false, reason: found.kind === "invalid" ? `session-${found.reason}` : "no-session" };
  }

  function ensureDevice({ ip, ua, label }) {
    const now = Date.now();
    for (const device of Object.values(state.devices)) {
      if (device.ua === ua && device.ip === ip) {
        device.lastSeenAt = now;
        if (label) device.label = label;
        return device;
      }
    }
    const id = randomBytes(9).toString("base64url");
    const device = {
      id,
      label: label || deviceLabel(ua),
      createdAt: now,
      lastSeenAt: now,
      ip,
      ua,
    };
    state.devices[id] = device;
    return device;
  }

  /**
   * Create a session, mint the dsh browser cookie and answer with a 303.
   * Shared by the password and pairing paths so they cannot drift apart.
   */
  async function completeLogin(req, res, { ip, via, next, label }) {
    const now = Date.now();
    const ua = String(req.headers?.["user-agent"] || "");
    const ttlSeconds = cfg.auth.sessionDays * 24 * 3600;
    const issued = issueSession({ secret: state.secret, ttlSeconds, ua, now });
    const device = ensureDevice({ ip, ua, label });
    state.sessions[issued.id] = {
      id: issued.id,
      issuedAt: issued.issuedAt,
      expiresAt: issued.expiresAt,
      uaHash: issued.uaHashValue,
      deviceId: device.id,
      ip,
      via,
      createdAt: now,
      lastSeenAt: now,
    };
    state.counters.logins += 1;
    state.counters.lastLoginAt = now;
    lockout.succeed(ip);

    // Mint *before* persisting: a mint can take ~10 ms, and the session must not
    // be observable to a concurrent request while the cookie is still missing.
    const minted = await mintForClient({ force: true });
    store.prune(now);
    store.save();

    const cookies = [sessionCookie({ value: issued.value, maxAge: ttlSeconds, secure: isSecure() })];
    cookies.push(...cookiesForClient(minted));
    const target = safeNext(next);
    sendRedirect(res, withMount(req, target), cookies);
    logger.info(`login ok via ${via} from ${ip} (dsh cookie: ${rt.dshSession})`);
  }

  // ── HTTP request pipeline ────────────────────────────────────────────────

  function rateLimited(ip, now) {
    const limit = Number(cfg.rateLimit) || 0;
    if (limit <= 0) return null;
    let entry = rt.rate.get(ip);
    if (!entry || now - entry.at >= RATE_WINDOW_MS) {
      entry = { at: now, count: 0 };
      rt.rate.set(ip, entry);
    }
    entry.count += 1;
    if (rt.rate.size > 2048) {
      for (const [key, value] of rt.rate) {
        if (now - value.at >= RATE_WINDOW_MS) rt.rate.delete(key);
      }
    }
    if (entry.count > limit) {
      return Math.max(1, Math.ceil((RATE_WINDOW_MS - (now - entry.at)) / 1000));
    }
    return null;
  }

  async function handleRequest(req, res) {
    const startedAt = Date.now();
    const ip = clientIp(req);
    const tag = { auth: "anon" };
    let logged = false;

    /**
     * Byte accounting.
     *
     * Content-length only exists on fixed-size responses, so a counter that reads
     * it alone reports zero for exactly the biggest transfers: the SPA bundle,
     * file downloads, and every stream. Wrapping `write` counts what actually
     * leaves the process, which makes `stats.bytesOut` a real number instead of a
     * decoration. The wrapper is transparent (same arguments, same return value)
     * and swallows its own errors so a counter can never break a response.
     */
    let streamedBytes = 0;
    const nativeWrite = res.write.bind(res);
    res.write = function countedWrite(chunk, encoding, callback) {
      try {
        if (chunk) {
          streamedBytes += typeof chunk === "string"
            ? Buffer.byteLength(chunk, typeof encoding === "string" ? encoding : "utf8")
            : chunk.length;
        }
      } catch {
        /* counting must never break the response */
      }
      return nativeWrite(chunk, encoding, callback);
    };

    const finalize = () => {
      if (logged) return;
      logged = true;
      let declared = 0;
      try {
        declared = Number(res.getHeader("content-length")) || 0;
      } catch {
        declared = 0;
      }
      recordAccess({
        ip, req, status: res.statusCode, startedAt, auth: tag.auth, ua: req.headers?.["user-agent"],
        // Prefer the counted value: it is right for chunked responses too, and it
        // equals content-length whenever that header exists.
        bytes: streamedBytes > 0 ? streamedBytes : declared,
      });
    };
    res.on("finish", finalize);
    res.on("close", finalize);

    const retryAfter = rateLimited(ip, Date.now());
    if (retryAfter !== null) {
      tag.auth = "rate-limited";
      sendText(res, 429, "too many requests\n", "text/plain; charset=utf-8", { "retry-after": String(retryAfter) });
      return;
    }

    const target = sanitizeTarget(req.url, req.method);
    if (!target.ok) {
      if (target.status === 405) {
        sendText(res, 405, `${target.reason}\n`, "text/plain; charset=utf-8", { allow: "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS" });
      } else {
        sendText(res, target.status, `${target.reason}\n`);
      }
      return;
    }

    if (target.isPortal) {
      await handlePortal(req, res, target, { ip, tag });
      return;
    }

    // §3 pipeline: static assets are answered before the auth gate. They are
    // presentation files only — never anything derived from state.
    if (target.decoded.startsWith(ASSET_PREFIX)) {
      serveAsset(req, res, target);
      return;
    }
    if (target.pathname === QR_PATH) {
      const served = await serveQr(req, res, target);
      if (served) return;
      // Fall through to the proxy: index.js may serve the same route locally.
    }

    // Outer shield: a cross-site Origin can only come from another site.
    const origin = originCheck(req);
    if (!origin.ok) {
      tag.auth = "blocked";
      sendText(res, 403, `forbidden: ${origin.reason}\n`);
      return;
    }

    const decision = authorize(req, ip);
    if (!decision.ok) {
      await respondUnauthenticated(req, res, { ip, tag, reason: decision.reason });
      return;
    }
    tag.auth = decision.auth;

    await proxyAuthorized(req, res, target, { ip, tag, decision });
  }

  /** Proxy an authorised request, including the 401 self-heal path. */
  async function proxyAuthorized(req, res, target, { ip, tag }) {
    const upstream = upstreamDescriptor();
    let retried = false;
    await proxy.request(req, res, {
      upstream,
      path: target.path,
      portalOrigin: portalOriginFor(req),
      secure: isSecure(),
      remoteAddress: ip,
      onUpstreamStatus: (status) => {
        if (status === 0) {
          rt.upstreamReachable = false;
          if (upstream.ok) rt.lastError = `upstream ${upstream.connectHost}:${upstream.port} did not answer`;
        } else {
          rt.upstreamReachable = true;
        }
      },
      onUnauthorized: async ({ attempt }) => {
        // Attempt 0: the browser's dsh cookie is missing or has been invalidated
        // by a dsh restart (the signing key rotates). Mint a fresh one and retry
        // the same request once — the user should not have to notice.
        if (attempt === 0 && !retried) {
          retried = true;
          const minted = await mintForClient({ force: true });
          const cookies = cookiesForClient(minted);
          if (cookies.length > 0) {
            tag.auth = "session+remint";
            return { retryCookies: cookies, setCookie: cookies };
          }
        }
        // Still 401: never let the phone land on dsh's bare text page.
        return { reply: await reauthReply(req, { next: safeNext(req.url) }) };
      },
    });
  }

  /** What the client gets when the upstream keeps refusing us. */
  async function reauthReply(req, { next }) {
    if (!wantsHtml(req)) {
      return {
        status: 401,
        contentType: "application/json; charset=utf-8",
        body: JSON.stringify({
          ok: false,
          code: "reauthenticate",
          error: "the remote session expired; reload to sign in again",
          login: `${PORTAL_PREFIX}/login`,
        }),
      };
    }
    const html = await renderLogin({
      lang: requestLang(req),
      req,
      mode: "password",
      error: "session-unauthorized",
      next,
    });
    return { status: 200, contentType: "text/html; charset=utf-8", body: html };
  }

  async function respondUnauthenticated(req, res, { ip, tag, reason }) {
    const lock = lockout.state(ip);
    if (lock.locked) {
      tag.auth = "locked";
      await renderLocked(req, res, lock.retryAfter);
      return;
    }
    if (wantsHtml(req)) {
      const mode = cfg.auth.mode === "pair-only" ? "pair" : "password";
      const error = reason.startsWith("session-") ? "session-unauthorized" : undefined;
      const info = !state.password && cfg.auth.mode === "password"
        ? (requestLang(req) === "zh"
          ? "尚未设置门户密码：请在本机打开 设置 → 远程访问 完成设置。"
          : "No portal password is set yet. Open Settings → Remote access on the host to finish setup.")
        : undefined;
      const html = await renderLogin({
        lang: requestLang(req),
      req,
        mode,
        error,
        info,
        next: safeNext(req.url),
      });
      sendHtml(res, 200, html);
      return;
    }
    sendJson(res, 401, {
      ok: false,
      code: "unauthorized",
      error: "authentication required",
      login: `${PORTAL_PREFIX}/login`,
    });
  }

  async function renderLocked(req, res, retryAfter) {
    if (!wantsHtml(req)) {
      // XHR/fetch clients get a machine-readable 429; only navigations get the
      // countdown page.
      sendJson(res, 429, {
        ok: false,
        code: "locked",
        error: "too many failed attempts",
        retryAfter,
      }, { "retry-after": String(retryAfter) });
      return;
    }
    const html = await renderLogin({
      lang: requestLang(req),
      req,
      mode: "locked",
      error: "too-many-attempts",
      retryAfter,
      next: "./",
    });
    sendHtml(res, 429, html, { "retry-after": String(retryAfter) });
  }

  // ── /__portal/* ─────────────────────────────────────────────────────────

  async function handlePortal(req, res, target, { ip, tag }) {
    const url = new URL(target.path, "http://portal.invalid");
    const pathname = url.pathname;

    // Same-origin guard for every portal endpoint except the QR entry point:
    // a scanned pairing URL may legitimately arrive as a cross-site navigation
    // (`Sec-Fetch-Site: cross-site`) when the user taps it in another page, but
    // a login POST, a logout or a pairing POST never may.
    const isPairGet = pathname === `${PORTAL_PREFIX}/pair` && (req.method === "GET" || req.method === "HEAD");
    if (!isPairGet) {
      const origin = originCheck(req);
      if (!origin.ok) {
        tag.auth = "blocked";
        sendJson(res, 403, { ok: false, code: "forbidden", reason: origin.reason });
        return;
      }
    }

    if (pathname === `${PORTAL_PREFIX}/health`) {
      if (req.method !== "GET" && req.method !== "HEAD") {
        sendJson(res, 405, { ok: false, error: "method-not-allowed" }, { allow: "GET" });
        return;
      }
      sendJson(res, 200, healthPayload());
      return;
    }
    if (pathname === `${PORTAL_PREFIX}/login`) {
      await handleLogin(req, res, url, { ip, tag });
      return;
    }
    if (pathname === `${PORTAL_PREFIX}/pair`) {
      await handlePairGet(req, res, url, { ip, tag });
      return;
    }
    if (pathname === `${PORTAL_PREFIX}/logout`) {
      await handleLogout(req, res, { ip, tag });
      return;
    }
    if (pathname === `${PORTAL_PREFIX}/manifest.webmanifest`) {
      sendManifest(req, res);
      return;
    }
    if (pathname === `${PORTAL_PREFIX}/icon.svg`) {
      servePluginIcon(req, res);
      return;
    }
    // A browser that lands here (a stale bookmark, a mistyped pairing link, the
    // old relative-redirect target) should end up on the app, not on a JSON blob.
    if (wantsHtml(req)) {
      sendRedirect(res, withMount(req, "/"));
      return;
    }
    sendJson(res, 404, { ok: false, code: "not-found", error: "no such portal endpoint" });
  }

  function healthPayload() {
    const upstream = upstreamFromContext(ctx);
    return {
      ok: true,
      name: PLUGIN_NAME,
      version,
      time: Date.now(),
      running: rt.running,
      state: rt.state,
      auth: {
        mode: cfg.auth.mode,
        passwordSet: Boolean(state.password),
        pairingActive: pairingActive(),
        dshSession: rt.dshSession,
      },
      upstream: {
        host: upstream.host,
        port: upstream.port,
        reachable: rt.upstreamReachable === true,
      },
      sessions: Object.keys(state.sessions).length,
      devices: Object.keys(state.devices).length,
    };
  }

  async function handlePairGet(req, res, url, { ip, tag }) {
    if (req.method !== "GET" && req.method !== "HEAD" && req.method !== "POST") {
      sendJson(res, 405, { ok: false, error: "method-not-allowed" }, { allow: "GET, POST" });
      return;
    }
    let token = String(url.searchParams.get("t") || url.searchParams.get("token") || "");
    if (token === "" && req.method === "POST") {
      try {
        const body = parseLoginBody(await readBody(req), req.headers["content-type"]);
        token = String(body.token || body.pairToken || "");
      } catch {
        token = "";
      }
    }
    if (token === "") {
      await respondPairFailure(req, res, { ip, tag, code: "pair-token-missing" });
      return;
    }
    await redeemPairing(req, res, token, { ip, tag, next: url.searchParams.get("next") });
  }

  async function handleLogin(req, res, url, { ip, tag }) {
    if (req.method === "GET" || req.method === "HEAD") {
      const mode = cfg.auth.mode === "pair-only" ? "pair" : "password";
      const html = await renderLogin({
        lang: requestLang(req),
      req,
        mode,
        next: safeNext(url.searchParams.get("next") || "./"),
        info: mode === "pair" && !pairingActive()
          ? (requestLang(req) === "zh" ? "当前没有有效的配对码，请在电脑端生成。" : "No active pairing code. Generate one on the host.")
          : undefined,
      });
      sendHtml(res, 200, html);
      return;
    }
    if (req.method !== "POST") {
      sendJson(res, 405, { ok: false, error: "method-not-allowed" }, { allow: "GET, POST" });
      return;
    }

    const lock = lockout.state(ip);
    if (lock.locked) {
      tag.auth = "locked";
      await renderLocked(req, res, lock.retryAfter);
      return;
    }

    let body;
    try {
      body = parseLoginBody(await readBody(req), req.headers["content-type"]);
    } catch (error) {
      sendText(res, error?.code === "body-too-large" ? 413 : 400, `${error?.code || "bad-request"}\n`);
      return;
    }

    const password = String(body.password ?? "");
    const token = String(body.token || body.pairToken || "");
    const next = body.next ?? url.searchParams.get("next") ?? "./";

    // A pair token arriving through the same form is a pairing redemption, not a
    // password attempt (auth-page renders both in one form).
    if (token !== "" && password === "") {
      await redeemPairing(req, res, token, { ip, tag, next });
      return;
    }

    if (cfg.auth.mode === "pair-only") {
      tag.auth = "blocked";
      await respondLoginFailure(req, res, {
        ip, tag, next,
        code: "password-mode-disabled",
        message: requestLang(req) === "zh" ? "此门户仅允许配对码登录。" : "This portal only accepts pairing codes.",
        status: 401,
      });
      return;
    }

    const ok = await verifyPassword(password, state.password);
    if (!ok || !state.password) {
      const after = lockout.fail(ip);
      state.counters.failures += 1;
      store.save();
      tag.auth = after.locked ? "locked" : "failed";
      if (after.locked) {
        await renderLocked(req, res, after.retryAfter);
        return;
      }
      await respondLoginFailure(req, res, {
        ip, tag, next,
        code: "invalid-password",
        message: requestLang(req) === "zh" ? "密码不正确，请重试。" : "Incorrect password.",
        status: 401,
        remaining: Math.max(1, cfg.auth.maxFailures - after.failures),
      });
      return;
    }

    await completeLogin(req, res, { ip, via: "password", next });
  }

  async function respondLoginFailure(req, res, { next, code, message, status, remaining }) {
    if (wantsHtml(req)) {
      const html = await renderLogin({
        lang: requestLang(req),
      req,
        mode: cfg.auth.mode === "pair-only" ? "pair" : "password",
        error: message,
        next,
      });
      sendHtml(res, status, html);
      return;
    }
    sendJson(res, status, {
      ok: false,
      code,
      error: message,
      ...(Number.isFinite(remaining) ? { remaining } : {}),
    });
  }

  async function respondPairFailure(req, res, { ip, tag, code }) {
    const after = lockout.fail(ip);
    tag.auth = after.locked ? "locked" : "failed";
    if (after.locked) {
      await renderLocked(req, res, after.retryAfter);
      return;
    }
    const lang = requestLang(req);
    const message = code === "pair-token-expired"
      ? (lang === "zh" ? "配对码已过期，请重新生成。" : "This pairing code has expired. Generate a new one.")
      : (lang === "zh" ? "配对码无效或已被使用。" : "This pairing code is invalid or already used.");
    if (wantsHtml(req)) {
      const html = await renderLogin({ req, lang, mode: "pair", error: message, next: "./" });
      sendHtml(res, 401, html);
      return;
    }
    sendJson(res, 401, { ok: false, code, error: message });
  }

  /**
   * Redeem a pairing token.
   *
   * Single use is enforced by writing `usedAt` and persisting *before* any
   * further work, so a failure later in the login cannot leave a replayable
   * token behind. The lookup compares every stored hash in constant time rather
   * than exiting on the first match.
   */
  async function redeemPairing(req, res, token, { ip, tag, next }) {
    const now = Date.now();
    const hash = hashToken(token);
    let match = null;
    for (const entry of Object.values(state.pairing)) {
      if (safeEqual(entry.hash, hash)) match = entry; // no early exit on purpose
    }
    if (!match) {
      await respondPairFailure(req, res, { ip, tag, code: "pair-token-unknown" });
      return;
    }
    if (match.usedAt) {
      await respondPairFailure(req, res, { ip, tag, code: "pair-token-used" });
      return;
    }
    if (!(match.expiresAt > now)) {
      await respondPairFailure(req, res, { ip, tag, code: "pair-token-expired" });
      return;
    }
    match.usedAt = now;
    store.save(); // single use takes effect immediately, even if the rest fails
    await completeLogin(req, res, { ip, via: "pair", next, label: match.label || undefined });
  }

  async function handleLogout(req, res, { ip, tag }) {
    if (req.method !== "POST" && req.method !== "GET") {
      sendJson(res, 405, { ok: false, error: "method-not-allowed" }, { allow: "GET, POST" });
      return;
    }
    const found = sessionFor(req, ip);
    if (found.kind === "session") {
      delete state.sessions[found.session.id];
      store.save();
    }
    tag.auth = "logout";
    const cookies = [clearCookie({ secure: isSecure() })];
    // Also expire the dsh browser cookies this client is holding: leaving a
    // valid dsh-auth cookie in a browser after "sign out" is a bad surprise.
    for (const name of Object.keys(parseCookies(req.headers?.cookie))) {
      if (name.toLowerCase().startsWith("dsh-auth-")) {
        const cookie = expireCookie(name, { secure: isSecure() });
        if (cookie) cookies.push(cookie);
      }
    }
    minter.invalidate();
    sendRedirect(res, withMount(req, "/"), cookies);
  }

  function sendManifest(req, res) {
    const icons = [];
    try {
      statSync(join(pluginRoot, "icon.svg"));
      icons.push({ src: `${PORTAL_PREFIX}/icon.svg`, sizes: "any", type: "image/svg+xml", purpose: "any" });
    } catch { /* icon is optional */ }
    sendJson(res, 200, {
      name: cfg.brand,
      short_name: "DSH",
      description: "DeepSeek Harness remote access",
      start_url: "/",
      scope: "/",
      display: "standalone",
      orientation: "any",
      background_color: "#ffffff",
      theme_color: "#0f1115",
      icons,
    }, {
      "content-type": "application/manifest+json; charset=utf-8",
      "cache-control": "no-cache",
    });
  }

  // ── static assets ────────────────────────────────────────────────────────

  function serveAsset(req, res, target) {
    if (req.method !== "GET" && req.method !== "HEAD") {
      sendText(res, 405, "method-not-allowed\n", "text/plain; charset=utf-8", { allow: "GET, HEAD" });
      return;
    }
    const relative = target.decoded.slice(ASSET_PREFIX.length);
    if (relative === "" || relative.includes("..") || relative.includes("\\") || relative.startsWith("/")) {
      sendText(res, 404, "not found\n");
      return;
    }
    const file = resolve(assetsDir, relative);
    if (file !== assetsDir && !file.startsWith(assetsDir + sep)) {
      sendText(res, 404, "not found\n");
      return;
    }
    const type = ASSET_TYPES.get(extname(file).toLowerCase());
    if (!type) {
      sendText(res, 404, "not found\n");
      return;
    }
    let stat;
    try {
      stat = statSync(file);
    } catch {
      sendText(res, 404, "not found\n");
      return;
    }
    if (!stat.isFile()) {
      sendText(res, 404, "not found\n");
      return;
    }
    // ETag first: a reload after the first visit should cost one 304, not 18 KB
    // of CSS over the tunnel. The tag is mtime+size, i.e. exactly what changes
    // when the linked plugin is rebuilt.
    const etag = `W/"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
    const inm = String(req.headers?.["if-none-match"] || "");
    if (inm !== "" && inm.split(",").some((tag) => tag.trim() === etag)) {
      res.writeHead(304, { ...SECURITY_HEADERS, etag, "cache-control": "no-cache" });
      res.end();
      return;
    }
    const headers = {
      ...SECURITY_HEADERS,
      "content-type": type,
      "content-length": stat.size,
      "cache-control": "no-cache",
      etag,
    };
    const acceptsGzip = /\bgzip\b/.test(String(req.headers?.["accept-encoding"] || ""));
    const compressible = /^(text\/|application\/(?:javascript|json))/.test(type) && stat.size > 1024;
    if (req.method === "HEAD") {
      res.writeHead(200, headers);
      res.end();
      return;
    }
    if (acceptsGzip && compressible) {
      let body;
      try {
        body = gzipSync(readFileSync(file));
      } catch {
        sendText(res, 500, "read failed\n");
        return;
      }
      res.writeHead(200, { ...headers, "content-encoding": "gzip", vary: "accept-encoding", "content-length": body.length });
      res.end(body);
      return;
    }
    res.writeHead(200, headers);
    const stream = createReadStream(file);
    stream.on("error", () => {
      try { res.destroy(); } catch { /* gone */ }
    });
    stream.pipe(res);
  }

  function servePluginIcon(req, res) {
    if (req.method !== "GET" && req.method !== "HEAD") {
      sendText(res, 405, "method-not-allowed\n");
      return;
    }
    try {
      const file = join(pluginRoot, "icon.svg");
      const body = readFileSync(file);
      res.writeHead(200, {
        ...SECURITY_HEADERS,
        "content-type": "image/svg+xml; charset=utf-8",
        "content-length": body.length,
        "cache-control": "no-cache",
      });
      res.end(req.method === "HEAD" ? undefined : body);
    } catch {
      sendText(res, 404, "not found\n");
    }
  }

  /** @returns {Promise<boolean>} false → the caller may proxy the request instead. */
  async function serveQr(req, res, target) {
    if (req.method !== "GET" && req.method !== "HEAD") return false;
    const module = await loadLocalModule(QR_FILE, "qrSvg");
    if (!module) return false;
    const url = new URL(target.path, "http://portal.invalid");
    const value = String(url.searchParams.get("text") || "");
    if (value === "") {
      sendText(res, 400, "text is required\n");
      return true;
    }
    // qr.mjs encodes versions 1–10 at ECC-M: 213 UTF-8 bytes is the hard ceiling
    // and it throws above that. Refuse instead of truncating — a sliced pairing
    // URL would produce a scannable code that authorises nothing.
    if (Buffer.byteLength(value, "utf8") > QR_MAX_BYTES) {
      sendText(res, 400, `text is too long (max ${QR_MAX_BYTES} UTF-8 bytes)\n`);
      return true;
    }
    try {
      const size = clamp(url.searchParams.get("size"), 64, 1024, 240);
      // Always paint the quiet zone white: the panel can be dark, and dark
      // modules on a dark card are unscannable. `label` is exposed by qr.mjs for
      // accessibility.
      const svg = module.qrSvg(value, { size, light: "#ffffff" });
      sendText(res, 200, svg, "image/svg+xml; charset=utf-8", { "cache-control": "no-cache" });
    } catch (error) {
      logger.warn(`qr rendering failed: ${text(error)}`);
      sendText(res, 400, "qr rendering failed\n");
    }
    return true;
  }

  // ── WebSocket upgrades ───────────────────────────────────────────────────

  async function handleUpgrade(req, socket, head) {
    const ip = clientIp(req);
    const startedAt = Date.now();
    const target = sanitizeTarget(req.url, req.method);
    if (!target.ok) {
      rejectUpgrade(socket, target.status, target.reason);
      return;
    }
    if (target.isPortal) {
      rejectUpgrade(socket, 404, "not-found");
      return;
    }
    const origin = originCheck(req);
    if (!origin.ok) {
      rejectUpgrade(socket, 403, origin.reason);
      return;
    }
    const decision = authorize(req, ip);
    if (!decision.ok) {
      rejectUpgrade(socket, 401, "authentication required");
      recordAccess({
        ip, req, status: 401, startedAt, auth: "upgrade-denied", ua: req.headers?.["user-agent"],
      });
      return;
    }
    const upstream = upstreamDescriptor();
    let cookieOverride;
    // A WebSocket handshake cannot be retried as cheaply as an HTTP request, so
    // pre-mint when the client has no dsh cookie at all (first socket of a fresh
    // session, or a browser that dropped it).
    if (upstream.ok && !hasDshCookie(req)) {
      const minted = cookiesForClient(await mintForClient({ force: false }));
      if (minted.length > 0) cookieOverride = withMintedCookies(req.headers?.cookie, minted);
    }
    recordAccess({
      ip, req, status: 101, startedAt, auth: `${decision.auth}:upgrade`, ua: req.headers?.["user-agent"],
    });
    proxy.upgrade(req, socket, head, {
      upstream,
      path: target.path,
      portalOrigin: portalOriginFor(req),
      secure: isSecure(),
      remoteAddress: ip,
      cookieOverride,
      onSocket: trackSocket,
    });
  }

  function trackSocket(socket) {
    if (!socket) return;
    rt.sockets.add(socket);
    socket.once("close", () => rt.sockets.delete(socket));
    socket.on("error", () => {
      try { socket.destroy(); } catch { /* gone */ }
    });
  }

  // ── lifecycle ────────────────────────────────────────────────────────────

  function createServer() {
    const handler = (req, res) => {
      Promise.resolve(handleRequest(req, res)).catch((error) => {
        logger.warn(`request failed: ${text(error)}`);
        if (!res.headersSent) sendJson(res, 500, { ok: false, code: "internal", error: "portal error" });
        else try { res.end(); } catch { /* gone */ }
      });
    };
    const tls = cfg.tls;
    let server;
    if (tls) {
      server = https.createServer({
        cert: readFileSync(tls.certFile),
        key: readFileSync(tls.keyFile),
      }, handler);
    } else {
      server = http.createServer(handler);
    }
    server.on("upgrade", (req, socket, head) => {
      Promise.resolve(handleUpgrade(req, socket, head)).catch((error) => {
        logger.warn(`upgrade failed: ${text(error)}`);
        rejectUpgrade(socket, 500, "portal error");
      });
    });
    server.on("clientError", (_error, socket) => {
      try {
        if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
        else socket.destroy();
      } catch { /* gone */ }
    });
    server.on("connection", trackSocket);
    server.keepAliveTimeout = 65_000; // > typical phone/proxy idle, avoids mid-SSE FIN
    server.headersTimeout = 70_000;
    server.requestTimeout = 0; // uploads through the portal may take minutes
    return server;
  }

  async function resolveBindHost(host) {
    const configured = String(host || "").trim();
    if (configured !== "auto") return configured;
    const list = await discoverAddresses({ fresh: true });
    const primary = list.find((entry) => entry.primary && entry.address) || list[0];
    if (!primary || !primary.address) {
      throw errorWith("no-lan-address", "host=auto but no LAN IPv4 address was found");
    }
    return primary.address;
  }

  function listen(server, host, port) {
    return new Promise((resolvePromise, rejectPromise) => {
      let settled = false;
      const onError = (error) => {
        if (settled) return;
        settled = true;
        server.removeListener("listening", onListening);
        try { server.close(); } catch { /* never listened */ }
        rejectPromise(error);
      };
      const onListening = () => {
        if (settled) return;
        settled = true;
        server.removeListener("error", onError);
        resolvePromise();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      try {
        server.listen({ host, port, exclusive: true });
      } catch (error) {
        onError(error);
      }
    });
  }

  async function start({ force = false } = {}) {
    if (!force && !cfg.enabled) {
      rt.state = "disabled";
      return;
    }
    if (rt.server) return;
    const bindHost = await resolveBindHost(cfg.host);
    try {
      assertBindSafe({ bindHost, passwordSet: Boolean(state.password), authMode: cfg.auth.mode });
    } catch (error) {
      rt.lastError = text(error);
      rt.state = "needs-password";
      rt.boundHost = bindHost;
      throw error;
    }
    const server = createServer();
    try {
      await listen(server, bindHost, cfg.port);
    } catch (error) {
      rt.lastError = describeBindError(error, bindHost, cfg.port);
      rt.state = "error";
      throw error;
    }
    rt.server = server;
    rt.running = true;
    rt.state = "listening";
    rt.startedAt = Date.now();
    rt.boundHost = bindHost;
    rt.protocol = cfg.tls ? "https:" : "http:";
    const address = server.address();
    rt.boundPort = address && typeof address === "object" ? Number(address.port) || 0 : cfg.port;
    rt.lastError = null;
    rt.addresses = await discoverAddresses({ fresh: true }).catch(() => discoverAddressesSync());
    await probeUpstream();
    lockout.configure({ maxFailures: cfg.auth.maxFailures, baseLockMs: cfg.auth.lockSeconds * 1000 });
    logger.info(`listening on ${bindHost}:${rt.boundPort} (auth=${cfg.auth.mode}, upstream=${ctx?.webServer?.port || 0})`);
    // The public tunnel rides on top of a working listener: its streams are
    // answered by this very gateway, so starting it before the bind would only
    // produce 502s at the relay.
    startTunnel();
  }

  // ── public tunnel (relay agent) ──────────────────────────────────────────

  /**
   * Keep one tunnel instance in step with the config. A change to the relay URL
   * or token tears the old one down and dials the new one; nothing else restarts
   * it, so a settings save does not drop a working public link.
   */
  function startTunnel() {
    const wanted = cfg.tunnel;
    if (!wanted) {
      stopTunnel();
      return;
    }
    const signature = `${wanted.url}|${wanted.token}|${wanted.caFile}|${wanted.insecure}`;
    if (rt.tunnel && rt.tunnelSignature === signature) return;
    stopTunnel();
    try {
      rt.tunnel = createTunnel({
        url: wanted.url,
        token: wanted.token,
        caFile: wanted.caFile || undefined,
        insecure: wanted.insecure === true,
        // Read per request: the listener port is stable, but reading it lazily
        // keeps the tunnel correct across a rebind.
        targetPort: () => rt.boundPort,
        log: logger,
      });
      rt.tunnelSignature = signature;
      Promise.resolve(rt.tunnel.start()).catch((error) => {
        logger.warn(`tunnel did not start: ${text(error)}`);
      });
      logger.info(`tunnel dialing ${wanted.url}`);
    } catch (error) {
      rt.tunnel = null;
      rt.tunnelSignature = "";
      logger.warn(`tunnel configuration rejected: ${text(error)}`);
    }
  }

  function stopTunnel() {
    const tunnel = rt.tunnel;
    rt.tunnel = null;
    rt.tunnelSignature = "";
    if (!tunnel) return;
    Promise.resolve(tunnel.stop()).catch(() => { /* best effort */ });
  }

  function describeBindError(error, host, port) {
    const code = error?.code || "";
    if (code === "EADDRINUSE") return `port ${port} on ${host} is already in use`;
    if (code === "EACCES") return `permission denied binding ${host}:${port}`;
    if (code === "EADDRNOTAVAIL") return `address ${host} is not available on this machine`;
    return `${code || "bind-error"}: ${text(error)}`;
  }

  async function stop() {
    stopTunnel();
    if (rt.flushTimer) {
      clearTimeout(rt.flushTimer);
      rt.flushTimer = null;
    }
    const server = rt.server;
    rt.server = null;
    rt.running = false;
    const sockets = [...rt.sockets];
    rt.sockets.clear();
    if (server) {
      await new Promise((resolvePromise) => {
        let settled = false;
        const finish = () => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolvePromise();
        };
        const timer = setTimeout(finish, 1500);
        timer.unref?.();
        try {
          server.close(() => finish());
        } catch {
          finish();
        }
        // closeAllConnections() handles keep-alive and in-flight requests; the
        // raw socket set covers upgraded connections, which Node stops tracking.
        try { server.closeAllConnections?.(); } catch { /* older node */ }
        for (const socket of sockets) {
          try { socket.destroy(); } catch { /* gone */ }
        }
      });
    }
    // Reset the proxy's keep-alive pool; a fresh start gets fresh sockets.
    proxy.destroy();
    flushState();
    store.prune();
    store.save();
    rt.boundPort = 0;
    rt.boundHost = "";
    rt.startedAt = 0;
    rt.state = cfg.enabled ? "stopped" : "disabled";
  }

  // ── public API ───────────────────────────────────────────────────────────

  function status() {
    const now = Date.now();
    store.prune(now);
    const upstream = upstreamFromContext(ctx);
    const { urls, lanUrls } = currentUrls();
    return {
      enabled: cfg.enabled,
      running: rt.running,
      state: rt.state,
      bindHost: rt.boundHost || cfg.host,
      port: rt.boundPort || cfg.port,
      protocol: rt.protocol,
      urls,
      lanUrls,
      passwordSet: Boolean(state.password),
      authMode: cfg.auth.mode,
      pairingActive: pairingActive(now),
      upstream: {
        host: upstream.host,
        port: upstream.port,
        reachable: rt.upstreamReachable === true,
      },
      dshSession: rt.dshSession,
      // Public access through a relay. `url` is what the panel shows and encodes
      // as a QR code; the token that produces it never leaves this host.
      public: publicStatus(),
      stats: {
        requests: state.counters.requests,
        sessions: Object.keys(state.sessions).length,
        devices: Object.keys(state.devices).length,
        uptimeMs: rt.running && rt.startedAt > 0 ? now - rt.startedAt : 0,
        bytesOut: state.counters.bytesOut,
        lastRequestAt: state.counters.lastRequestAt,
        lastLoginAt: state.counters.lastLoginAt,
      },
      lastError: rt.lastError,
    };
  }

  /**
   * What the panel needs to know about the public link, and nothing more.
   * `configured` distinguishes "no relay set up" from "relay set up but offline",
   * which are two very different things to tell a user who is not at home.
   */
  function publicStatus() {
    const configured = Boolean(cfg.tunnel);
    if (!configured) return { configured: false, state: "off", url: "", tunnelId: "", lastError: null };
    let detail = null;
    try { detail = rt.tunnel ? rt.tunnel.status() : null; } catch { detail = null; }
    if (!detail) {
      return {
        configured: true,
        state: rt.running ? "connecting" : "offline",
        url: "",
        tunnelId: "",
        lastError: rt.running ? null : "the local listener is not running",
        endpoint: safeEndpoint(cfg.tunnel.url),
      insecure: Boolean(cfg.tunnel.insecure),
      };
    }
    return {
      configured: true,
      state: detail.status,
      url: detail.publicUrl || "",
      tunnelId: detail.tunnelId || "",
      lastError: detail.lastError || null,
      endpoint: detail.endpoint,
      connectedAt: detail.connectedAt || 0,
      insecure: Boolean(cfg.tunnel && cfg.tunnel.insecure),
      stats: detail.stats,
    };
  }

  /** An endpoint URL without userinfo, safe to show in the panel. */
  function safeEndpoint(value) {
    try {
      const url = new URL(String(value));
      return `${url.protocol}//${url.host}`;
    } catch {
      return "";
    }
  }

  function publicConfig() {
    return {
      enabled: cfg.enabled,
      host: cfg.host,
      port: cfg.port,
      mobile: cfg.mobile,
      tls: cfg.tls ? { certFile: cfg.tls.certFile, keyFile: cfg.tls.keyFile } : null,
      // Never the token: only "set up or not" and where it dials.
      tunnel: cfg.tunnel ? { url: cfg.tunnel.url, tokenSet: true, caFile: cfg.tunnel.caFile || "", insecure: cfg.tunnel.insecure === true } : null,
      auth: {
        mode: cfg.auth.mode,
        sessionDays: cfg.auth.sessionDays,
        maxFailures: cfg.auth.maxFailures,
        lockSeconds: cfg.auth.lockSeconds,
      },
      stateDir: dir,
    };
  }

  async function applyConfig(patch = {}) {
    // The panel never receives the tunnel token back, so a URL-only save arrives
    // without it. Reuse the stored secret instead of rejecting the whole patch.
    if (isObject(patch) && isObject(patch.tunnel) && !patch.tunnel.token && cfg.tunnel?.token) {
      patch = { ...patch, tunnel: { ...patch.tunnel, token: cfg.tunnel.token } };
    }
    const before = cfg;
    const next = normalizeConfig(patch, before);
    const picked = pickOverrides(patch);
    const overrides = { ...state.overrides, ...picked };
    if (isObject(picked.auth)) overrides.auth = { ...(state.overrides.auth || {}), ...picked.auth };
    state.overrides = overrides;
    cfg = next;
    lockout.configure({ maxFailures: cfg.auth.maxFailures, baseLockMs: cfg.auth.lockSeconds * 1000 });
    store.save();

    const bindChanged = next.host !== before.host || next.port !== before.port ||
      JSON.stringify(next.tls) !== JSON.stringify(before.tls);
    try {
      if (!next.enabled) {
        await stop();
        rt.state = "disabled";
      } else if (bindChanged || !rt.running) {
        if (rt.server) await stop();
        await start({ force: true });
      } else {
        rt.state = "listening";
      }
    } catch (error) {
      // A bind failure is a panel-visible state, not an exception: the user must
      // be able to see "port in use" and change it without a whole-app error.
      rt.lastError = error?.code === "needs-password" ? text(error) : rt.lastError || text(error);
      rt.state = error?.code === "needs-password" ? "needs-password" : "error";
      logger.warn(`applyConfig did not (re)start the listener: ${text(error)}`);
      rt.addresses = await discoverAddresses().catch(() => addresses());
    }
    // A relay-only change (url/token) does not rebind anything, so the tunnel is
    // reconciled here: startTunnel() is a no-op unless the signature changed.
    if (rt.running) startTunnel();
    return status();
  }

  async function setPassword(password, { revokeAll = false, minLength = MIN_PASSWORD_LENGTH } = {}) {
    const value = typeof password === "string" ? password : "";
    if (value.length < minLength) {
      throw errorWith("password-too-short", `password must be at least ${minLength} characters`);
    }
    if (value.length > 200) throw errorWith("password-too-long", "password is too long");
    state.password = await hashPassword(value);
    if (revokeAll) {
      state.sessions = {};
      state.devices = {};
      state.pairing = {};
    }
    store.save();
    // A portal that was refused because it had no password can now start. This
    // is the flow the panel drives: turn the portal on, get "needs-password",
    // set one, watch it come up.
    if (cfg.enabled && !rt.running && rt.state === "needs-password") {
      try {
        await start({ force: true });
      } catch (error) {
        logger.warn(`listener still not running after setPassword: ${text(error)}`);
      }
    }
    return status();
  }

  async function mintPairing({ ttlSeconds = 180, label = "" } = {}) {
    const ttl = clamp(ttlSeconds, 30, 900, 180);
    const now = Date.now();
    const { token, hash, id } = mintPairToken();
    state.pairing[id] = {
      id,
      hash,
      label: String(label || "").slice(0, 64),
      createdAt: now,
      expiresAt: now + ttl * 1000,
      usedAt: 0,
    };
    store.prune(now);
    store.save();
    const { lanUrls, urls } = currentUrls();
    const base = lanUrls[0] || urls[0] || `http://127.0.0.1:${rt.boundPort || cfg.port}/`;
    let url = "";
    try {
      url = new URL(`${PORTAL_PREFIX}/pair?t=${encodeURIComponent(token)}`, base).toString();
    } catch {
      url = "";
    }
    // The raw token leaves the process exactly once, in this return value.
    return { id, token, url, expiresAt: now + ttl * 1000, expiresIn: ttl, label: String(label || "").slice(0, 64) };
  }

  function devices() {
    return Object.values(state.devices)
      .map((device) => ({
        id: device.id,
        label: device.label,
        createdAt: device.createdAt,
        lastSeenAt: device.lastSeenAt,
        ip: device.ip,
        ua: device.ua,
        sessions: Object.values(state.sessions).filter((s) => s.deviceId === device.id).length,
      }))
      .sort((a, b) => b.lastSeenAt - a.lastSeenAt);
  }

  async function revokeDevice(id) {
    const key = String(id || "").trim();
    if (key === "" || !state.devices[key]) return false;
    delete state.devices[key];
    for (const [sessionId, session] of Object.entries(state.sessions)) {
      if (session.deviceId === key) delete state.sessions[sessionId];
    }
    store.save();
    return true;
  }

  async function mintBrowserCookie() {
    return cookiesForClient(await mintForClient({ force: true }));
  }

  function accessLog(limit = 50) {
    const count = clamp(limit, 1, 100, 50);
    return state.accessLog.slice(-count).reverse().map((entry) => ({ ...entry }));
  }

  async function diagnose({ lang } = {}) {
  const zh = lang === "zh";
  const N = (en, cn) => (zh ? cn : en);
    try {
      // The reachability flag is only set by a probe. On a freshly booted host
      // nothing has needed the upstream yet, so the card would otherwise report
      // "unreachable" for a perfectly healthy server — the opposite of helpful in
      // a troubleshooting view. Probe on demand (bounded) before answering.
      if (rt.upstreamReachable === null) {
        try { await probeUpstream(); } catch { /* keep the unknown state */ }
      }
      const upstream = upstreamFromContext(ctx);
      const list = addresses();
      const port = rt.boundPort || cfg.port;
      const bindHost = rt.boundHost || cfg.host;
      const notes = [];
      if (!rt.running) notes.push(cfg.enabled ? N("the portal listener is not running", "门户未在监听") : N("the portal is disabled", "门户已关闭"));
      if (!state.password && cfg.auth.mode === "password") {
        notes.push(N("no portal password is set: a non-loopback bind is refused until one is set", "尚未设置访问密码：在设置之前，非回环地址会被拒绝监听"));
      }
      if (cfg.auth.mode === "pair-only") notes.push(N("pair-only mode: sessions can only be created by redeeming a pairing code", "仅配对模式：只能通过兑换配对码登录"));
      if (!upstream.ok) notes.push(N("the dsh web server has not bound a port yet; proxying resumes as soon as it does", "dsh Web 服务尚未监听端口，就绪后会自动恢复转发"));
      if (rt.lastError && /EADDRINUSE|already in use/i.test(String(rt.lastError))) {
        // The usual cause is a second dsh instance on the same DSH_HOME (two
        // profiles, or a stale process), which is worth saying out loud.
        notes.push(N(`port ${port} is held by another process — another dsh instance may already be running this portal; close it or pick a different port`, `端口 ${port} 被其他进程占用——可能已有另一个 dsh 实例在运行本门户；请关闭它或换一个端口`));
      }
      if (rt.upstreamReachable === false && upstream.ok) notes.push(N(`nothing is answering on ${upstream.connectHost}:${upstream.port}`, `${upstream.connectHost}:${upstream.port} 无响应`));
      if (rt.upstreamReachable === null) notes.push(N("upstream reachability has not been probed yet", "尚未探测上游可达性"));
      if (rt.dshSession === "unavailable") {
        notes.push(N("browser-cookie minting is unavailable: remote sign-in may end at dsh's own 401 page", "无法签发浏览器 Cookie：远程登录可能停在 dsh 自己的 401 页面"));
      }
      if (rt.lastError) notes.push(N(`last error: ${rt.lastError}`, `最近一次错误：${rt.lastError}`));
      if (isWildcard(bindHost) && list.length === 0) notes.push(N("no LAN IPv4 address was found; only loopback will work", "未找到局域网 IPv4 地址，仅本机可访问"));
      if (cfg.host === "auto") notes.push(N("host=auto binds the current primary LAN address; it changes when the network does", "host=auto 绑定当前主局域网地址，网络变化时会随之改变"));
      if (cfg.auth.mode === "open") notes.push(N("open mode: anyone who can reach this port gets the dsh UI (loopback only)", "开放模式：能访问该端口的人都能进入 dsh（仅限回环）"));
      if (changingPortLikelyBlocked()) notes.push(N(`if the phone cannot connect, allow TCP ${port} through the firewall`, `若手机连不上，请在防火墙放行 TCP ${port}`));
      return {
        bindHost,
        port,
        listening: rt.running,
        addresses: list.map((entry) => ({
          iface: entry.iface,
          address: entry.address,
          family: entry.family,
          primary: Boolean(entry.primary),
        })),
        upstream: {
          host: upstream.host,
          port: upstream.port,
          reachable: rt.upstreamReachable === true,
          // `reachable` stays a boolean for the panel's happy path; the third
          // state ("not probed yet") is reported separately instead of being
          // silently folded into "unreachable".
          reachableKnown: rt.upstreamReachable !== null,
          protocol: upstream.protocol,
        },
        tunnel: publicStatus(),
        firewallHint: process.platform === "win32"
          ? `netsh advfirewall firewall add rule name="dsh-remote-portal" dir=in action=allow protocol=TCP localport=${port}`
          : null,
        notes,
      };
    } catch (error) {
      // diagnose() is a troubleshooting endpoint: a broken report must never be
      // the reason the panel cannot be opened.
      return {
        bindHost: rt.boundHost || cfg.host,
        port: rt.boundPort || cfg.port,
        listening: rt.running,
        addresses: [],
        upstream: { host: "", port: 0, reachable: false, protocol: rt.protocol },
        firewallHint: null,
        notes: [`diagnose failed: ${text(error)}`],
      };
    }
  }

  function changingPortLikelyBlocked() {
    return rt.running && !isLoopback(rt.boundHost || cfg.host);
  }

  return {
    version,
    pluginDir: pluginRoot,
    start,
    stop,
    applyConfig,
    status,
    config: publicConfig,
    setPassword,
    mintPairing,
    devices,
    revokeDevice,
    mintBrowserCookie,
    accessLog,
    diagnose,
    // Not part of the documented API, but useful for the panel's "test now"
    // action and for tests: re-probe the upstream without a request.
    refresh: async () => ({ reachable: await probeUpstream(), status: status(), diagnose: diagnose() }),
  };
}

// ───────────────────────────────────────────────────────────────────────────
// fallbacks
// ───────────────────────────────────────────────────────────────────────────

function readOwnVersion() {
  try {
    const file = fileURLToPath(new URL("../package.json", import.meta.url));
    const pkg = JSON.parse(readFileSync(file, "utf8"));
    return typeof pkg.version === "string" ? pkg.version : "";
  } catch {
    return "";
  }
}

/**
 * Minimal login document, used only until (or unless) auth-page's
 * `lib/login-page.mjs` is available. Deliberately tiny — the real page is the
 * product surface; this exists so a late module can never brick the gateway.
 */
function fallbackLoginPage(opts) {
  const zh = opts.lang === "zh";
  const title = zh ? "需要登录" : "Sign in";
  const label = zh ? "密码" : "Password";
  const submit = zh ? "登录" : "Sign in";
  const hint = zh ? "使用门户密码登录后即可访问 dsh Web 界面。" : "Sign in with the portal password to reach the dsh Web UI.";
  const error = opts.error ? `<p role="alert" class="err">${escapeHtml(String(opts.error))}</p>` : "";
  const info = opts.info ? `<p class="info">${escapeHtml(String(opts.info))}</p>` : "";
  const retry = Number(opts.retryAfter) > 0
    ? `<p class="info">${zh ? "请在" : "Try again in"} ${Number(opts.retryAfter)}s ${zh ? "后重试。" : ""}</p>`
    : "";
  const pair = opts.pairToken
    ? `<form method="post" action="${PORTAL_PREFIX}/login"><input type="hidden" name="token" value="${escapeHtml(String(opts.pairToken))}"><button type="submit">${zh ? "授权此设备" : "Authorise this device"}</button></form>`
    : "";
  const mode = opts.mode === "locked" ? "locked" : opts.mode === "pair" ? "pair" : "password";
  return `<!doctype html>
<html lang="${zh ? "zh-Hans" : "en"}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="light dark">
<title>${escapeHtml(title)} · ${escapeHtml(opts.brand || "DeepSeek Harness")}</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
         background: #fff; color: #0f1115; padding: max(16px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom)); }
  main { width: 100%; max-width: 380px; }
  h1 { font-size: 20px; margin: 0 0 4px; font-weight: 600; }
  p.sub { margin: 0 0 20px; color: #61666b; font-size: 14px; }
  label { display: block; font-size: 13px; font-weight: 500; margin-bottom: 6px; }
  input[type=password] { width: 100%; padding: 12px; font-size: 16px; border: 1px solid #0000001a; border-radius: 10px; background: #fff; color: inherit; }
  input[type=password]:focus-visible, button:focus-visible { outline: 2px solid #4176e6; outline-offset: 2px; }
  button { width: 100%; margin-top: 14px; padding: 13px; font-size: 15px; font-weight: 600; border: 0; border-radius: 10px;
           background: #0f1115; color: #fff; min-height: 44px; cursor: pointer; }
  .err { color: #ec1313; font-size: 14px; margin: 0 0 12px; }
  .info { color: #61666b; font-size: 14px; margin: 0 0 12px; }
  footer { margin-top: 24px; color: #81858c; font-size: 12px; }
  @media (prefers-color-scheme: dark) {
    body { background: #151517; color: #f9fafb; }
    p.sub, .info, footer { color: #adb2b8; }
    input[type=password] { background: #232324; border-color: #ffffff1f; }
    button { background: #f9fafb; color: #353638; }
  }
</style>
</head>
<body data-portal-mode="${mode}">
<main>
  <h1>${escapeHtml(title)}</h1>
  <p class="sub">${escapeHtml(hint)}</p>
  ${error}${info}${retry}
  <form method="post" action="${PORTAL_PREFIX}/login" autocomplete="on">
    <input type="hidden" name="next" value="${escapeHtml(String(opts.next || "./"))}">
    <label for="password">${escapeHtml(label)}</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required ${mode === "locked" ? "disabled" : ""}>
    <button type="submit" ${mode === "locked" ? "disabled" : ""}>${escapeHtml(submit)}</button>
  </form>
  ${pair}
  <footer>${escapeHtml(opts.brand || "DeepSeek Harness")} · v${escapeHtml(String(opts.version || ""))}${
    opts.lanHint ? ` · ${escapeHtml(String(opts.lanHint))}` : ""
  }</footer>
</main>
</body>
</html>`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => (
    char === "&" ? "&amp;" : char === "<" ? "&lt;" : char === ">" ? "&gt;" : char === '"' ? "&quot;" : "&#39;"
  ));
}













