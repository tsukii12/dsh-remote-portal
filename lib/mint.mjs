/**
 * dsh-remote-portal — server-side minting of a dsh *browser* cookie.
 *
 * dsh's Web UI authenticates with a cookie minted from the launch token it
 * prints at startup (`http://127.0.0.1:<port>/?token=…`). A phone on the LAN
 * never sees that URL, so the portal — which runs *inside* the dsh process —
 * performs the exchange for it:
 *
 *   ctx.get("connection").authenticatedUrl(origin)  →  …/?token=<launch token>
 *   GET that URL on loopback (Host/Origin rewritten like any proxied request)
 *   copy every `Set-Cookie` of the 303 onto our own response
 *
 * Two traps this module exists to avoid (both cost hours in the reference
 * implementation, see dsh-remote-web's `mintHarnessCookie`):
 *
 *  1. **Never follow the redirect.** The token exchange answers `303 → ./` and
 *     the `Set-Cookie` only exists on the 303 itself. A followed redirect
 *     silently yields an empty cookie jar. `node:http` never follows redirects,
 *     so this is structurally impossible here.
 *  2. **Never assume the cookie name.** It is `dsh-auth-<hash>`, where the hash
 *     is derived from the authority — anything else in the response is not ours
 *     to relay. We filter, and report a failed mint rather than leaking some
 *     unrelated cookie into the phone's jar.
 *
 * The launch token is a bearer credential for the whole dsh session: it is never
 * logged, never returned, and never persisted. Only the resulting cookie values
 * are cached (in memory, a few minutes).
 */
import http from "node:http";
import https from "node:https";

/** dsh browser cookies all start with this. */
export const DSH_COOKIE_PREFIX = "dsh-auth-";
/** The dsh signing key rotates on restart; re-mint well before a session dies. */
export const DEFAULT_TTL_MS = 4 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 6000;

/**
 * Runtime lookup of the `connection` service.
 *
 * Deliberately does *not* use `inject`: a profile without the service would then
 * fail plugin activation entirely. Absent service ⇒ no browser auth in this host
 * ⇒ nothing to mint (the proxy then surfaces the upstream 401, and the gateway's
 * 401-recovery path turns that into a login page instead of dead text).
 */
export function resolveConnectionService(ctx) {
  if (!ctx) return null;
  let holder;
  try {
    holder = typeof ctx.get === "function" ? ctx.get("connection") : undefined;
  } catch {
    holder = undefined;
  }
  if (!holder) {
    try {
      holder = ctx.connection;
    } catch {
      holder = undefined;
    }
  }
  if (!holder) return null;
  if (typeof holder.authenticatedUrl === "function") return holder;
  // Some hosts wrap the service one level deeper (`{ connection: { … } }`).
  const inner = holder.connection;
  if (inner && typeof inner.authenticatedUrl === "function") return inner;
  return null;
}

/**
 * Ask the host for a token URL and keep only sane results.
 * Tries the origin with and without a trailing slash: the API has accepted both
 * shapes across dsh versions, and a missing token is indistinguishable from a
 * wrong origin without looking.
 */
export function tokenUrlFor(svc, origin) {
  const base = String(origin || "").replace(/\/+$/, "");
  if (base === "") return null;
  for (const candidate of [`${base}/`, base]) {
    let raw = "";
    try {
      raw = svc.authenticatedUrl(candidate);
    } catch {
      continue;
    }
    if (!raw) continue;
    let url;
    try {
      url = new URL(String(raw));
    } catch {
      continue;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") continue;
    // A URL without a token is useless for exchanging (it would just land on the
    // 401 page and set nothing) — require the query parameter.
    if (![...url.searchParams.keys()].some((key) => /token/i.test(key))) continue;
    return url;
  }
  return null;
}

/**
 * Decode the (unsigned) payload of a `dsh-auth-*` cookie value.
 * Used only for diagnostics: dsh v1 cookies embed `{version, authority, …}` as
 * base64url JSON. Never used as an authorisation decision.
 */
export function cookieAuthority(setCookieValue) {
  try {
    const raw = String(setCookieValue || "").split(";")[0];
    const eq = raw.indexOf("=");
    if (eq < 0) return "";
    const value = raw.slice(eq + 1);
    const parts = value.split(".");
    if (parts.length < 2 || parts[0] !== "v1") return "";
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    return typeof payload?.authority === "string" ? payload.authority : "";
  } catch {
    return "";
  }
}

/** True when a raw `Set-Cookie` value is one of dsh's browser cookies. */
export function isDshCookie(raw) {
  return typeof raw === "string" && raw.trim().toLowerCase().startsWith(DSH_COOKIE_PREFIX);
}

/**
 * Make a dsh `Set-Cookie` value safe to relay to *our* client.
 *
 * - `Secure` is dropped when the portal itself is plain HTTP: a browser silently
 *   refuses a Secure cookie set over http://, which presents as "login succeeds
 *   but the app keeps asking" — the single most confusing failure mode here.
 * - `Domain=` is dropped: dsh sets host-only cookies on loopback; relaying a
 *   Domain attribute would scope them to the LAN hostname, which is not what we
 *   want (we want exactly the host the phone used, same as dsh gets).
 * - `SameSite=Strict` is relaxed to `Lax`: the portal's own login POST is a
 *   same-site navigation, and Strict has bitten browsers restoring tabs.
 */
export function sanitizeSetCookie(raw, { secure = false } = {}) {
  let value = String(raw || "").trim();
  if (!isDshCookie(value)) return null;
  const parts = value.split(";");
  const kept = [parts[0]];
  for (const attr of parts.slice(1)) {
    const name = attr.split("=")[0].trim().toLowerCase();
    if (name === "secure" && !secure) continue;
    if (name === "domain") continue;
    if (name === "samesite") {
      kept.push("SameSite=Lax");
      continue;
    }
    kept.push(attr.trim());
  }
  if (!kept.some((attr) => /^samesite=/i.test(attr))) kept.push("SameSite=Lax");
  if (!kept.some((attr) => /^httponly$/i.test(attr))) kept.push("HttpOnly");
  return kept.join("; ");
}

/**
 * @param {object} opts
 * @param {object} opts.ctx          cordis context (may be a test double)
 * @param {object} [opts.log]        { info, warn, error }
 * @param {number} [opts.ttlMs]      cache lifetime for a minted cookie set
 * @param {number} [opts.timeoutMs]  loopback request budget
 */
export function createMinter({ ctx, log, ttlMs = DEFAULT_TTL_MS, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const logger = log || { info() {}, warn() {}, error() {} };
  /** @type {{key:string, cookies:string[], at:number}|null} */
  let cache = null;
  /** @type {Promise<string[]>|null} */
  let inflight = null;
  /** "unknown" until the first attempt; then "ok" | "unavailable". */
  let lastResult = "unknown";
  let lastAt = 0;
  let notedNoService = false;
  let notedAuthorityMismatch = "";

  function available() {
    return resolveConnectionService(ctx) !== null;
  }

  function noteResult(result, detail) {
    lastResult = result;
    lastAt = Date.now();
    if (detail) logger.warn(`browser cookie mint: ${detail}`);
  }

  /**
   * Perform the exchange. Returns raw `Set-Cookie` values (full headers,
   * attributes included) or `[]` — never throws.
   */
  async function exchange(upstream) {
    const svc = resolveConnectionService(ctx);
    if (!svc) {
      if (!notedNoService) {
        notedNoService = true;
        // One line, no token, no URL: just "this host has no browser auth".
        logger.info("browser cookie mint unavailable: host has no connection service (remote sign-in will rely on dsh's own 401)");
      }
      lastResult = "unavailable";
      lastAt = Date.now();
      return [];
    }
    const origin = `${upstream.protocol}//${upstream.authority}`;
    const tokenUrl = tokenUrlFor(svc, origin);
    if (!tokenUrl) {
      noteResult("unavailable", "host did not return a usable token URL");
      return [];
    }
    const sets = await requestSetCookies(tokenUrl, upstream);
    if (sets === null) {
      lastResult = "unavailable";
      lastAt = Date.now();
      return [];
    }
    const cookies = sets.filter(isDshCookie);
    if (cookies.length === 0) {
      noteResult("unavailable", `token exchange returned ${sets.length} cookie(s), none of them ${DSH_COOKIE_PREFIX}*`);
      return [];
    }
    // Diagnostic only: if dsh bound the cookie to another authority than the one
    // the proxy presents, every proxied request will 401. Say so once, without
    // revealing any token material.
    const bound = cookieAuthority(cookies[0]);
    if (bound && bound !== upstream.authority) {
      const key = `${bound}|${upstream.authority}`;
      if (notedAuthorityMismatch !== key) {
        notedAuthorityMismatch = key;
        logger.warn(
          `browser cookie is bound to ${bound} but the portal proxies to ${upstream.authority}; proxied requests will be rejected`,
        );
      }
    } else {
      notedAuthorityMismatch = "";
    }
    lastResult = "ok";
    lastAt = Date.now();
    return cookies;
  }

  /**
   * One GET against the token URL. `node:http` on purpose: `fetch` forbids
   * setting `Host`, and we must present the same authority the browser would.
   */
  function requestSetCookies(tokenUrl, upstream) {
    return new Promise((resolve) => {
      const mod = tokenUrl.protocol === "https:" ? https : http;
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        resolve(value);
      };
      let request;
      try {
        request = mod.request({
          protocol: tokenUrl.protocol,
          hostname: tokenUrl.hostname,
          port: tokenUrl.port || (tokenUrl.protocol === "https:" ? 443 : 80),
          method: "GET",
          path: `${tokenUrl.pathname}${tokenUrl.search}`,
          agent: false, // a fresh connection: this is a one-shot exchange
          headers: {
            // The dsh trust fence compares Host and Origin against its own
            // authority; both are rewritten exactly as the proxy would.
            host: tokenUrl.host,
            origin: `${tokenUrl.protocol}//${tokenUrl.host}`,
            accept: "text/html,*/*;q=0.8",
            "user-agent": `dsh-remote-portal/${upstream.portalVersion || "0"}`,
            connection: "close",
          },
        });
      } catch (error) {
        noteResult("unavailable", error?.message || String(error));
        return finish(null);
      }
      request.setTimeout(timeoutMs, () => {
        noteResult("unavailable", "token exchange timed out");
        request.destroy();
        finish(null);
      });
      request.on("error", (error) => {
        // Only the code: a request error message can contain the full URL.
        noteResult("unavailable", `token exchange failed (${error?.code || error?.name || "error"})`);
        finish(null);
      });
      request.on("response", (response) => {
        const raw = response.headers["set-cookie"];
        const sets = Array.isArray(raw) ? raw.slice() : raw ? [String(raw)] : [];
        const status = Number(response.statusCode) || 0;
        // Drain and discard the body: it is a redirect or a 401 text page.
        response.resume();
        response.on("end", () => finish({ status, sets }));
        response.on("error", () => finish({ status, sets }));
      });
      request.end();
    }).then((result) => {
      if (!result) return null;
      if (result.status >= 400) {
        noteResult("unavailable", `token exchange answered ${result.status}`);
        return [];
      }
      return result.sets;
    });
  }

  return {
    available,

    /**
     * Minted cookie values, cached for `ttlMs`.
     * @param {{protocol:string,authority:string,portalVersion?:string}} upstream
     * @param {{force?:boolean}} [opts]
     * @returns {Promise<string[]>} raw Set-Cookie values (possibly empty)
     */
    async mint(upstream, { force = false } = {}) {
      if (!upstream || !upstream.authority) return [];
      const key = `${upstream.protocol}//${upstream.authority}`;
      if (!force && cache && cache.key === key && Date.now() - cache.at < ttlMs) {
        return cache.cookies.slice();
      }
      if (inflight) return (await inflight).slice();
      inflight = (async () => {
        try {
          const cookies = await exchange(upstream);
          if (cookies.length > 0) cache = { key, cookies, at: Date.now() };
          else if (cache && cache.key === key) cache = null; // do not serve a set we just proved stale
          return cookies;
        } catch (error) {
          // Defensive: exchange() handles its own errors, but a bug here must not
          // propagate into the login path.
          noteResult("unavailable", `mint failed (${error?.name || "error"})`);
          return [];
        } finally {
          inflight = null;
        }
      })();
      const out = await inflight;
      return out.slice();
    },

    /** Forget the cached cookie set (called when upstream answers 401). */
    invalidate() {
      cache = null;
    },

    /** Non-secret diagnostics: is minting possible, and how did it go last time? */
    state() {
      return {
        available: available(),
        status: lastResult === "ok" ? "ok" : lastResult === "unavailable" ? "unavailable" : "unknown",
        lastAt,
        cached: Boolean(cache),
        cachedAt: cache ? cache.at : 0,
      };
    },
  };
}
