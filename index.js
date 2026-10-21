/**
 * dsh-remote-portal — host entry (the node half of the plugin).
 *
 * Two responsibilities, and nothing else:
 *
 *  1. own the lifetime of the portal gateway (a second, authenticated HTTP/WS
 *     listener in front of this process's dsh Web UI), and
 *  2. expose a small same-origin control API under `/dsh-remote-portal/*`
 *     that the Settings panel calls.
 *
 * Why a second listener instead of widening the dsh web server: dsh rejects
 * wildcard binds on purpose and its browser surface authenticates with a
 * per-process launch token that is printed to the console — neither can be
 * changed from inside a running process. So the portal keeps dsh's own
 * security model untouched and puts a real gate (password / one-time QR
 * pairing, device registry, lockout) in front of it. See ARCHITECTURE.md §3.
 *
 * Every registration below is owned by the plugin's context and removed on
 * unload; a failure here must never take the Web app down with it (a broken
 * plugin row would otherwise cost the user their whole UI), so the gateway
 * start is fire-and-forget and every handler is wrapped.
 */
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { readFile, readdir, realpath, stat as stat_ } from "node:fs/promises";
import { gzipSync } from "node:zlib";
import { homedir } from "node:os";
import { statSync } from "node:fs";
import { createGateway } from "./lib/gateway.mjs";

/** dsh waits for the Web carrier before this row can bind its own listener. */
export const inject = ["webServer"];

const PLUGIN_NAME = "dsh-remote-portal";
// Bumped with package.json; also used to invalidate the injected asset URLs.
const PLUGIN_VERSION = "0.2.6";
const PREFIX = "/dsh-remote-portal";
const HERE = dirname(fileURLToPath(import.meta.url));
const ASSET_DIR = join(HERE, "assets");
const ASSET_TYPES = new Map([
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".svg", "image/svg+xml; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".png", "image/png"],
  [".webp", "image/webp"],
]);

// ───────────────────────────────────────────────────────────────────────────
// small helpers
// ───────────────────────────────────────────────────────────────────────────

/** Plugin-prefixed logger that never throws when the host logger is absent. */
function makeLogger(ctx) {
  const sink = (level) => (msg) => {
    try {
      const logger = ctx?.logger;
      if (logger && typeof logger[level] === "function") logger[level](`${PLUGIN_NAME}: ${msg}`);
      else if (level === "error" || level === "warn") console.warn(`${PLUGIN_NAME}: ${msg}`);
    } catch {
      /* logging is never allowed to break a request */
    }
  };
  return { info: sink("info"), warn: sink("warn"), error: sink("error") };
}

/** Resolve `~` and environment references in a configured path. */
function expandHome(value) {
  const raw = String(value ?? "").trim();
  if (raw === "") return "";
  if (raw === "~") return homedir();
  if (raw.startsWith("~/") || raw.startsWith("~\\")) return join(homedir(), raw.slice(2));
  return raw;
}

/** `<DSH_HOME>/dsh-remote-portal` unless the row overrides it. */
function resolveStateDir(config) {
  const explicit = expandHome(config?.stateDir);
  if (explicit !== "") return explicit;
  const home = String(process.env.DSH_HOME || "").trim() || join(homedir(), ".dsh");
  return join(home, "dsh-remote-portal");
}

function sendJson(res, status, body) {
  if (res.headersSent) {
    try { res.end(); } catch { /* already gone */ }
    return;
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(payload);
}

function sendText(res, status, text, type = "text/plain; charset=utf-8") {
  if (res.headersSent) {
    try { res.end(); } catch { /* already gone */ }
    return;
  }
  res.writeHead(status, {
    "content-type": type,
    "content-length": Buffer.byteLength(text),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(text);
}

/** Read and parse a JSON body with a hard size cap (control payloads are tiny). */
async function readJsonBody(req, limit = 64 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw Object.assign(new Error("body too large"), { status: 413 });
    chunks.push(chunk);
  }
  if (size === 0) return {};
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (text === "") return {};
  try {
    const value = JSON.parse(text);
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("body must be a JSON object");
    }
    return value;
  } catch (error) {
    throw Object.assign(new Error(`invalid JSON body: ${error?.message || error}`), { status: 400 });
  }
}

/** "zh" when the caller asks for it, "en" otherwise. */
function requestLang(req) {
  try {
    const url = new URL(String(req?.url || "/"), "http://portal.invalid");
    const explicit = String(url.searchParams.get("lang") || "").toLowerCase();
    if (explicit === "zh" || explicit === "en") return explicit;
    const accept = String(req?.headers?.["accept-language"] || "").toLowerCase();
    return accept.includes("zh") ? "zh" : "en";
  } catch {
    return "en";
  }
}

function headerHost(req) {
  // `Host` is the only authority a browser cannot forge for a same-origin
  // request; IPv6 literals arrive bracketed, so parse through URL.
  const host = String(req.headers?.host || "").trim();
  if (host === "") return null;
  try {
    return new URL(`http://${host.includes("://") ? host.split("://")[1] : host}/`).host;
  } catch {
    return null;
  }
}

function isLoopbackName(name) {
  const n = String(name || "").toLowerCase().replace(/^\[|\]$/g, "");
  return n === "localhost" || n === "::1" || n === "0:0:0:0:0:0:0:1" || /^127\./.test(n);
}

/**
 * Same-origin guard for the control routes.
 *
 * These routes are *not* behind dsh's `/api` trust fence (that fence belongs to
 * the Connection service), so a page on evil.example could otherwise POST to
 * them through the user's browser. We re-implement the two checks that matter:
 * the claimed authority must be one this process actually serves, and an
 * attached Origin must name that same authority. Returns a reason string when
 * the request must be refused.
 */
function crossSiteReason(req, bindHost) {
  const host = headerHost(req);
  if (host === null) return "missing-or-invalid-host";
  const hostname = host.startsWith("[") ? host.slice(1, host.indexOf("]")) : host.split(":")[0];
  const bind = String(bindHost || "").replace(/^\[|\]$/g, "");
  if (!isLoopbackName(hostname) && hostname !== bind) return "untrusted-host";
  const origin = req.headers?.origin;
  if (typeof origin === "string" && origin !== "") {
    if (origin === "null") return "null-origin";
    try {
      if (new URL(origin).host !== host) return "cross-origin";
    } catch {
      return "invalid-origin";
    }
  }
  if (String(req.headers?.["sec-fetch-site"] || "").toLowerCase() === "cross-site") return "cross-site";
  return null;
}

// ───────────────────────────────────────────────────────────────────────────
// assets
// ───────────────────────────────────────────────────────────────────────────

/**
 * Serve one file from `assets/`. The path is resolved and then verified to stay
 * inside the directory — a whitelist of extensions on top keeps `/assets/..`
 * style probes answerable with a flat 404.
 *
 * Two things make this cheap on a phone: a strong-ish ETag (mtime + size) so a
 * reload costs a 304 instead of 18 KB of CSS, and gzip for the text assets when
 * the client asks for it. Both files are re-read per request on purpose — the
 * plugin is a link, so a rebuild must be visible without a restart.
 */
async function serveAsset(req, res, relative) {
  const clean = normalize(String(relative || "")).replace(/^([./\\])+/, "");
  const target = join(ASSET_DIR, clean);
  const inside = target === ASSET_DIR || target.startsWith(ASSET_DIR + sep);
  if (!inside) return sendText(res, 404, "not found");
  const type = ASSET_TYPES.get(extname(target).toLowerCase());
  if (!type) return sendText(res, 404, "not found");
  try {
    const stat = await stat_(target);
    const etag = `W/"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
    const inm = String(req?.headers?.["if-none-match"] || "");
    if (inm !== "" && inm.split(",").some((tag) => tag.trim() === etag)) {
      res.writeHead(304, { etag, "cache-control": "no-cache" });
      res.end();
      return;
    }
    let body = await readFile(target);
    const headers = {
      "content-type": type,
      "cache-control": "no-cache",
      "x-content-type-options": "nosniff",
      etag,
    };
    const acceptsGzip = /\bgzip\b/.test(String(req?.headers?.["accept-encoding"] || ""));
    if (acceptsGzip && body.length > 1024 && /^(text|application\/(?:javascript|json))/.test(type)) {
      body = gzipSync(body);
      headers["content-encoding"] = "gzip";
      headers.vary = "accept-encoding";
    }
    headers["content-length"] = body.length;
    res.writeHead(200, headers);
    res.end(body);
  } catch {
    sendText(res, 404, "not found");
  }
}

// ───────────────────────────────────────────────────────────────────────────
// control routes
// ───────────────────────────────────────────────────────────────────────────

/**
 * The panel's whole API. Everything is same-origin, JSON in/out, and answers
 * `{ ok: true, … }` or `{ ok: false, error, code? }` — never a bare 500.
 *
 * @returns {Array<{ kind: "exact"|"prefix", path: string, methods: string[], run: Function }>}
 */
/** `?path=` from the request; empty means "start at home". */
function readFsPath(req) {
  try {
    const url = new URL(String(req?.url || "/"), "http://portal.invalid");
    return String(url.searchParams.get("path") || "");
  } catch {
    return "";
  }
}

/** Roots a user would expect to start from on this host. */
function fsRoots() {
  const roots = [{ name: `~ ${homedir()}`, path: homedir() }];
  if (process.platform === "win32") {
    for (let c = 65; c <= 90; c += 1) {
      const drive = `${String.fromCharCode(c)}:\\`;
      try {
        if (statSync(drive)) roots.push({ name: drive, path: drive });
      } catch { /* a drive letter that does not exist */ }
    }
  } else {
    roots.push({ name: "/", path: "/" });
  }
  return roots;
}

/**
 * One directory level, directories only.
 *
 * No recursion, no file contents, a hard cap on entries and a timeout, so a
 * hanging network share cannot hang the panel.
 */
async function listDirectories(rawPath) {
  const requested = String(rawPath || "").trim();
  if (requested.includes("\u0000")) {
    throw Object.assign(new Error("invalid path"), { status: 400, code: "bad-path" });
  }
  const target = requested === "" ? homedir() : requested;
  let resolved;
  try {
    resolved = await realpath(target);
  } catch {
    throw Object.assign(new Error(`not found: ${target}`), { status: 404, code: "not-found" });
  }
  const info = await stat_(resolved).catch(() => null);
  if (!info || !info.isDirectory()) {
    throw Object.assign(new Error(`not a directory: ${resolved}`), { status: 400, code: "not-a-directory" });
  }

  const listing = await Promise.race([
    readdir(resolved, { withFileTypes: true }),
    new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 4000)),
  ]).catch(() => []);
  const dirs = listing
    .filter((entry) => entry.isDirectory() || entry.isSymbolicLink())
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

  const entries = [];
  for (const dirent of dirs.slice(0, 400)) {
    const full = join(resolved, dirent.name);
    try {
      const targetInfo = await stat_(full);
      if (!targetInfo.isDirectory()) continue; // a symlink to a file is not a choice
    } catch {
      continue;
    }
    entries.push({ name: dirent.name, path: full, hidden: dirent.name.startsWith(".") });
  }

  const parent = dirname(resolved);
  return {
    path: resolved,
    parent: parent === resolved ? "" : parent,
    roots: fsRoots(),
    entries,
    truncated: dirs.length > entries.length,
  };
}

function routeTable(portal, log) {
  const wrap = (fn) => async (req, res) => {
    try {
      const body = req.method === "POST" ? await readJsonBody(req) : {};
      const result = await fn(req, res, body);
      if (result !== undefined && !res.headersSent) sendJson(res, 200, { ok: true, ...result });
    } catch (error) {
      const status = Number(error?.status) || 500;
      if (status >= 500) log.warn(`${req.method} ${req.url} failed: ${error?.stack || error}`);
      sendJson(res, status, {
        ok: false,
        code: error?.code || (status === 500 ? "internal" : "bad-request"),
        error: String(error?.message || error),
      });
    }
  };

  return [
    {
      kind: "exact", path: `${PREFIX}/status`, methods: ["GET"],
      run: wrap(async () => ({ status: portal.status() })),
    },
    {
      kind: "exact", path: `${PREFIX}/config`, methods: ["POST"],
      run: wrap(async (_req, _res, body) => {
        // Only keys the caller actually sent may reach the gateway: a patch that
        // carries `enabled: undefined` reads as "disable" downstream, so a panel
        // saving just a port would switch the portal off. `tls` is part of the
        // contract even though the panel has no UI for it yet (scripted setups).
        const patch = {};
        for (const key of ["enabled", "host", "port", "auth", "mobile", "tls", "tunnel"]) {
          if (Object.prototype.hasOwnProperty.call(body, key) && body[key] !== undefined) patch[key] = body[key];
        }
        return { status: await portal.applyConfig(patch) };
      }),
    },
    {
      kind: "exact", path: `${PREFIX}/password`, methods: ["POST"],
      run: wrap(async (_req, _res, body) => {
        const password = typeof body.password === "string" ? body.password : "";
        if (password.length < 6) {
          throw Object.assign(new Error("password must be at least 6 characters"), { status: 400, code: "weak-password" });
        }
        if (password.length > 200) {
          throw Object.assign(new Error("password is too long"), { status: 400, code: "password-too-long" });
        }
        await portal.setPassword(password, { revokeAll: body.revokeAll === true });
        return { status: portal.status() };
      }),
    },
    {
      kind: "exact", path: `${PREFIX}/pair`, methods: ["POST"],
      run: wrap(async (_req, _res, body) => {
        const ttl = Number(body.ttlSeconds);
        const pairing = await portal.mintPairing({
          ttlSeconds: Number.isFinite(ttl) && ttl > 0 ? Math.min(Math.max(ttl, 30), 900) : undefined,
          label: typeof body.label === "string" ? body.label.slice(0, 60) : undefined,
        });
        return { pairing, status: portal.status() };
      }),
    },
    {
      kind: "exact", path: `${PREFIX}/devices`, methods: ["GET"],
      run: wrap(async () => ({ devices: portal.devices() })),
    },
    {
      kind: "exact", path: `${PREFIX}/devices/revoke`, methods: ["POST"],
      run: wrap(async (_req, _res, body) => {
        const id = typeof body.id === "string" ? body.id : "";
        if (id === "") throw Object.assign(new Error("device id is required"), { status: 400 });
        const removed = await portal.revokeDevice(id);
        return { removed, devices: portal.devices(), status: portal.status() };
      }),
    },
    {
      kind: "exact", path: `${PREFIX}/start`, methods: ["POST"],
      run: wrap(async () => ({ status: await portal.applyConfig({ enabled: true }) })),
    },
    {
      kind: "exact", path: `${PREFIX}/stop`, methods: ["POST"],
      run: wrap(async () => ({ status: await portal.applyConfig({ enabled: false }) })),
    },
    {
      kind: "exact", path: `${PREFIX}/restart`, methods: ["POST"],
      run: wrap(async () => {
        await portal.stop();
        await portal.start();
        return { status: portal.status() };
      }),
    },
    {
      kind: "exact", path: `${PREFIX}/access-log`, methods: ["GET"],
      run: wrap(async () => ({ entries: portal.accessLog(50) })),
    },
    {
      kind: "exact", path: `${PREFIX}/diagnose`, methods: ["GET"],
      // `diagnose()` may probe the upstream before answering, hence the await.
      run: wrap(async (req) => ({ report: await portal.diagnose({ lang: requestLang(req) }) })),
    },
    {
      // Test hook + panel footer: proves which build is loaded without a reload.
      kind: "exact", path: `${PREFIX}/version`, methods: ["GET"],
      run: wrap(async () => ({ version: portal.version, plugin: PLUGIN_NAME })),
    },
    {
      // Directory browser for the workspace picker. It lists directories on
      // *this* host, which is the whole point: the app's native picker resolves
      // paths on whatever device opened the page, and a phone cannot use those.
      // Names only — no file contents, one level per request.
      kind: "exact", path: `${PREFIX}/fs`, methods: ["GET"],
      run: wrap(async (req) => ({ listing: await listDirectories(readFsPath(req)) })),
    },
    {
      // QR is rendered on the host so the browser half stays dependency-free.
      // The encoder tops out at 213 UTF-8 bytes (version 10, ECC M); an over-long
      // text is refused instead of truncated, because a truncated pairing token
      // would scan into a symbol that authenticates nothing. The light module
      // colour is forced opaque white: a transparent quiet zone over the dark
      // page is the classic "looks fine, never scans" failure.
      kind: "exact", path: `${PREFIX}/qr.svg`, methods: ["GET"],
      run: async (req, res) => {
        const url = new URL(req.url ?? "/", "http://dsh.invalid");
        const text = String(url.searchParams.get("text") || "");
        if (text === "") return sendText(res, 400, "text is required");
        if (Buffer.byteLength(text, "utf8") > 213) {
          return sendText(res, 400, "text is too long for a QR symbol (max 213 UTF-8 bytes)");
        }
        try {
          const { qrSvg } = await import("./lib/qr.mjs");
          const size = Math.min(Math.max(Number(url.searchParams.get("size")) || 240, 96), 640);
          const svg = qrSvg(text, { size, light: "#ffffff", dark: "#0f1115" });
          sendText(res, 200, svg, "image/svg+xml; charset=utf-8");
        } catch (error) {
          log.warn(`qr.svg unavailable: ${error?.message || error}`);
          sendText(res, 503, "qr renderer unavailable");
        }
      },
    },
    {
      kind: "prefix", path: `${PREFIX}/assets`, methods: ["GET", "HEAD"],
      run: async (req, res) => {
        const url = new URL(req.url ?? "/", "http://dsh.invalid");
        const relative = decodeURIComponent(url.pathname.slice(`${PREFIX}/assets/`.length));
        await serveAsset(req, res, relative);
      },
    },
  ];
}

/**
 * Register every control route on the dsh web server.
 *
 * `ctx.webServer.register` matches an exact path across the whole table first,
 * then the longest prefix, so an exact `/dsh-remote-portal/status` can never be
 * shadowed by the `/assets` prefix route.
 *
 * @returns {() => void} one disposer that removes all routes
 */
function registerControlRoutes(ctx, portal, log) {
  const disposers = [];
  const bindHost = () => {
    try { return ctx.webServer?.host ?? ""; } catch { return ""; }
  };

  for (const route of routeTable(portal, log)) {
    let dispose;
    try {
      dispose = ctx.webServer.register({
        kind: route.kind,
        path: route.path,
        handler: (req, res) => {
          const pathname = new URL(req.url ?? "/", "http://dsh.invalid").pathname;
          const matches = route.kind === "exact"
            ? pathname === route.path
            : pathname === route.path || pathname.startsWith(route.path + "/");
          if (!matches) {
            res.writeHead(404);
            res.end();
            return;
          }
          if (!route.methods.includes(req.method || "GET")) {
            res.writeHead(405, { allow: route.methods.join(", ") });
            res.end();
            return;
          }
          const blocked = crossSiteReason(req, bindHost());
          if (blocked !== null) {
            log.warn(`refused control request ${req.method} ${pathname} (${blocked})`);
            sendJson(res, 403, { ok: false, error: "forbidden", reason: blocked });
            return;
          }
          Promise.resolve(route.run(req, res)).catch((error) => {
            log.warn(`${pathname} handler failed: ${error?.stack || error}`);
            if (!res.headersSent) sendJson(res, 500, { ok: false, error: String(error?.message || error) });
            else try { res.end(); } catch { /* gone */ }
          });
        },
      });
    } catch (error) {
      // One collision (another plugin already claims this path, or the route
      // table changed under us) must cost that one endpoint, not the plugin —
      // an activation failure here would take the whole panel down with it.
      log.warn(`could not register ${route.path}: ${error?.message || error}`);
      continue;
    }
    if (typeof dispose === "function") disposers.push(dispose);
  }

  return () => {
    for (const dispose of disposers) {
      try { dispose(); } catch { /* already disposed */ }
    }
  };
}

// ───────────────────────────────────────────────────────────────────────────
// plugin entry
// ───────────────────────────────────────────────────────────────────────────

/**
 * @param ctx - host cordis context (injects `webServer`).
 * @param config - entry config from cordis.patch.yml, see ARCHITECTURE.md §5.
 */
export function apply(ctx, config = {}) {
  const log = makeLogger(ctx);
  const stateDir = resolveStateDir(config);

  let portal;
  try {
    portal = createGateway({
      ctx,
      config,
      stateDir,
      log,
      pluginDir: HERE,
      pluginVersion: PLUGIN_VERSION,
    });
  } catch (error) {
    // A construction failure must not cost the user their Web UI: report it and
    // leave the control panel running against an inert portal object instead.
    log.error(`gateway construction failed: ${error?.stack || error}`);
    return;
  }

  ctx.effect(() => {
    let stopped = false;
    // A quick dsh restart can leave the previous gateway's port in TIME_WAIT, and
    // Windows then refuses the new bind with EADDRINUSE for a few seconds. Retry
    // with backoff instead of leaving the portal dead until the user toggles it;
    // the panel still shows the reason if every attempt fails.
    const delays = [0, 1000, 2000, 4000, 8000, 15000];
    let attempt = 0;
    const tryStart = () => {
      if (stopped) return;
      Promise.resolve()
        .then(() => portal.start())
        .catch((error) => {
          if (stopped) return;
          attempt += 1;
          const wait = delays[attempt];
          if (wait === undefined) {
            log.warn(`gateway did not start after ${attempt} attempts: ${error?.message || error}`);
            return;
          }
          log.warn(`gateway start failed (${error?.message || error}); retrying in ${wait} ms`);
          const timer = setTimeout(tryStart, wait);
          if (typeof timer.unref === "function") timer.unref();
        });
    };
    tryStart();
    return () => {
      stopped = true;
      Promise.resolve()
        .then(() => portal.stop())
        .catch((error) => log.warn(`gateway stop failed: ${error?.message || error}`));
    };
  }, `${PLUGIN_NAME}: portal listener`);

  ctx.effect(() => registerControlRoutes(ctx, portal, log), `${PLUGIN_NAME}: control routes`);

  // Mobile presentation layer: as index rows, so the stylesheet is in the very
  // first parse and the phone never sees a desktop layout flash. The client
  // half injects the same two assets as a fallback (idempotent by marker), which
  // is what carries the Electron shell, where index rows are not rendered.
  if (config?.mobile !== false) {
    ctx.effect(() => {
      const row = {
        kind: "html",
        placement: "head",
        html:
          // `?v=` is what makes a reload pick up a new layer: the file URL is
          // otherwise stable across plugin upgrades and browsers cache it hard.
          `<link rel="stylesheet" href="${PREFIX}/assets/mobile.css?v=${PLUGIN_VERSION}" data-plugin="${PLUGIN_NAME}" data-drp="mobile-css-host">` +
          `<script defer src="${PREFIX}/assets/mobile.js?v=${PLUGIN_VERSION}" data-plugin="${PLUGIN_NAME}" data-drp="mobile-js-host"></script>`,
      };
      const listener = (table) => {
        if (Array.isArray(table)) table.push(row);
      };
      const off = ctx.on?.("webserver/index-inject", listener);
      return () => {
        try {
          if (typeof off === "function") off();
        } catch {
          /* already disposed */
        }
      };
    }, `${PLUGIN_NAME}: index injections`);
  }

  log.info(`ready — state in ${stateDir}, panel at ${PREFIX}/status`);
}














