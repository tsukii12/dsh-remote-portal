/**
 * dsh-remote-portal — authentication primitives.
 *
 * Pure functions plus one stateful helper (the lockout), so every rule in
 * ARCHITECTURE.md §3 is unit-testable without a listener:
 *
 *   password   scrypt (N=16384, r=8, p=1) + 16-byte salt, constant-time compare
 *   session    `<id>.<issuedAt>.<expiresAt>.<hmac>` cookie, HMAC-SHA256 over
 *              `id|issuedAt|expiresAt|uaHash` with the per-install secret
 *   pairing    32 random bytes base64url, single use, stored as SHA-256
 *   lockout    5 failures / 10 min → 60 s, doubling, capped at 15 min
 *
 * The UA binding is deliberately part of the *signature* rather than a separate
 * field: a stolen cookie replayed from another browser fails the MAC check and
 * is indistinguishable from a tampered one (nothing to learn from the reply).
 */
import {
  createHash, createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual,
} from "node:crypto";

export const PORTAL_COOKIE = "dsh_portal";
export const SCRYPT_PARAMS = { N: 16384, r: 8, p: 1, keylen: 64, maxmem: 64 * 1024 * 1024 };
export const MIN_PASSWORD_LENGTH = 8;

const scrypt = (password, salt, keylen, opts) =>
  new Promise((resolve, reject) => {
    scryptCb(password, salt, keylen, opts, (error, key) => (error ? reject(error) : resolve(key)));
  });

// ───────────────────────────────────────────────────────────────────────────
// password
// ───────────────────────────────────────────────────────────────────────────

/** Hash a password for `state.json`. Returns the record, never the password. */
export async function hashPassword(password) {
  const salt = randomBytes(16);
  const key = await scrypt(String(password), salt, SCRYPT_PARAMS.keylen, {
    N: SCRYPT_PARAMS.N, r: SCRYPT_PARAMS.r, p: SCRYPT_PARAMS.p, maxmem: SCRYPT_PARAMS.maxmem,
  });
  return {
    alg: "scrypt",
    salt: salt.toString("base64url"),
    hash: Buffer.from(key).toString("base64url"),
    N: SCRYPT_PARAMS.N,
    r: SCRYPT_PARAMS.r,
    p: SCRYPT_PARAMS.p,
    keylen: SCRYPT_PARAMS.keylen,
    updatedAt: Date.now(),
  };
}

/**
 * A fixed dummy record used when no password is configured.
 *
 * Why: "is a password set?" must not be answerable by timing. Without this,
 * the no-password path returns in microseconds while a real check spends ~60 ms
 * in scrypt, which turns the login form into an oracle. With it, both paths pay
 * the same cost and the answer is always `false`.
 */
const DUMMY_RECORD = {
  alg: "scrypt",
  salt: Buffer.alloc(16, 0x5a).toString("base64url"),
  hash: Buffer.alloc(64, 0x00).toString("base64url"),
  ...SCRYPT_PARAMS,
  updatedAt: 0,
};

/** @returns {Promise<boolean>} true only when a record exists and the password matches. */
export async function verifyPassword(password, record) {
  const usable = record && typeof record.hash === "string" && typeof record.salt === "string";
  const rec = usable ? record : DUMMY_RECORD;
  let key;
  try {
    key = Buffer.from(await scrypt(String(password ?? ""), Buffer.from(rec.salt, "base64url"), rec.keylen, {
      N: rec.N, r: rec.r, p: rec.p, maxmem: SCRYPT_PARAMS.maxmem,
    }));
  } catch {
    return false;
  }
  const expected = Buffer.from(rec.hash, "base64url");
  const equal = key.length === expected.length && timingSafeEqual(key, expected);
  return Boolean(usable) && equal;
}

// ───────────────────────────────────────────────────────────────────────────
// constant-time helpers
// ───────────────────────────────────────────────────────────────────────────

/**
 * Compare two strings without leaking a prefix length.
 *
 * Hashing first equalises the length (timingSafeEqual throws on a length
 * mismatch, which would itself be an oracle for pairing-token length).
 */
export function safeEqual(a, b) {
  const left = createHash("sha256").update(String(a ?? "")).digest();
  const right = createHash("sha256").update(String(b ?? "")).digest();
  return timingSafeEqual(left, right);
}

/** Cookie names/paths are ASCII; refuse anything that could split a header. */
export function cookieSafe(value) {
  return typeof value === "string" && value.length > 0 && !/[\u0000-\u0020\u007f;,]/.test(value);
}

// ───────────────────────────────────────────────────────────────────────────
// sessions
// ───────────────────────────────────────────────────────────────────────────

/** Stable, non-reversible binding between a session and the browser's UA. */
export function uaHash(ua) {
  return createHash("sha256").update(String(ua || "")).digest("base64url").slice(0, 32);
}

export function signSession({ secret, id, issuedAt, expiresAt, ua }) {
  return createHmac("sha256", String(secret))
    .update(`${id}|${issuedAt}|${expiresAt}|${uaHash(ua)}`)
    .digest("base64url");
}

/**
 * Build a new session. The returned `value` is the cookie payload
 * (`id.issuedAt.expiresAt.sig`); the caller persists `id/issuedAt/expiresAt/uaHash`
 * and hands `value` to the browser.
 */
export function issueSession({ secret, ttlSeconds = 30 * 24 * 3600, ua, now = Date.now(), bytes = 16 }) {
  const id = randomBytes(bytes).toString("base64url");
  const issuedAt = now;
  const expiresAt = now + Math.max(60, Math.floor(ttlSeconds)) * 1000;
  return {
    id,
    issuedAt,
    expiresAt,
    uaHashValue: uaHash(ua),
    sig: signSession({ secret, id, issuedAt, expiresAt, ua }),
    value: `${id}.${issuedAt}.${expiresAt}.${signSession({ secret, id, issuedAt, expiresAt, ua })}`,
  };
}

/** Parse a Cookie header into a plain object. Last value wins (browser order). */
export function parseCookies(header) {
  const out = Object.create(null);
  if (typeof header !== "string" || header === "") return out;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 1) continue;
    const name = part.slice(0, eq).trim();
    if (!name) continue;
    out[name] = part.slice(eq + 1).trim();
  }
  return out;
}

const COOKIE_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

/**
 * Verify a portal cookie value.
 * @returns {{ok:true,id:string,issuedAt:number,expiresAt:number}|{ok:false,reason:string}}
 */
export function verifySessionCookie(value, { secret, ua, now = Date.now() } = {}) {
  const parts = String(value ?? "").split(".");
  if (parts.length !== 4) return { ok: false, reason: "malformed" };
  const [id, iat, exp, sig] = parts;
  if (!COOKIE_ID_RE.test(id)) return { ok: false, reason: "bad-id" };
  const issuedAt = Number(iat);
  const expiresAt = Number(exp);
  if (!Number.isFinite(issuedAt) || !Number.isFinite(expiresAt)) return { ok: false, reason: "bad-time" };
  // 60 s of clock tolerance: the cookie is issued and verified by the same
  // process, but a suspended laptop resumes with a jumped wall clock.
  if (issuedAt > now + 60_000) return { ok: false, reason: "not-yet-valid" };
  if (expiresAt <= now) return { ok: false, reason: "expired" };
  if (!cookieSafe(sig) || sig.length > 64) return { ok: false, reason: "bad-sig" };
  const expected = signSession({ secret, id, issuedAt, expiresAt, ua });
  if (!safeEqual(sig, expected)) return { ok: false, reason: "bad-sig" };
  return { ok: true, id, issuedAt, expiresAt };
}

/** `Set-Cookie` value for a portal session (`SameSite=Lax` per §3). */
export function sessionCookie({ value, maxAge, secure = false, name = PORTAL_COOKIE }) {
  const bits = [
    `${name}=${value}`,
    "Path=/",
    "HttpOnly",
    "SameSite=Lax",
    `Max-Age=${Math.max(0, Math.floor(maxAge))}`,
    `Expires=${new Date(Date.now() + Math.max(0, maxAge) * 1000).toUTCString()}`,
  ];
  if (secure) bits.push("Secure");
  return bits.join("; ");
}

export function clearCookie({ secure = false, name = PORTAL_COOKIE } = {}) {
  return sessionCookie({ value: "", maxAge: 0, secure, name });
}

/** Expire an arbitrary cookie name at the same path (used for dsh-auth-* on logout). */
export function expireCookie(name, { secure = false } = {}) {
  if (!cookieSafe(name)) return null;
  return `${name}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT${secure ? "; Secure" : ""}`;
}

// ───────────────────────────────────────────────────────────────────────────
// pairing tokens
// ───────────────────────────────────────────────────────────────────────────

/** 32 random bytes → 43 chars of base64url; only the hash is persisted. */
export function mintPairToken() {
  const token = randomBytes(32).toString("base64url");
  return { token, hash: hashToken(token), id: randomBytes(9).toString("base64url") };
}

export function hashToken(token) {
  return createHash("sha256").update(String(token ?? "")).digest("base64url");
}

// ───────────────────────────────────────────────────────────────────────────
// lockout
// ───────────────────────────────────────────────────────────────────────────

export const LOCKOUT_DEFAULTS = {
  /** Failures are counted inside this sliding window. */
  windowMs: 10 * 60 * 1000,
  maxFailures: 5,
  baseLockMs: 60 * 1000,
  maxLockMs: 15 * 60 * 1000,
  /** After this long without a failure the escalation resets to strike 1. */
  decayMs: 60 * 60 * 1000,
};

/**
 * Per-IP failure lockout.
 *
 * Shape of the escalation: the 5th failure inside 10 min locks the IP for 60 s;
 * each further batch of 5 doubles it (120 s, 240 s, …) up to 15 min. A
 * successful login clears the strikes, and an hour of quiet decays them. The
 * window is cleared when a lock starts, so after the lock expires the client
 * gets a fresh (but still small) budget rather than being insta-locked by the
 * failures that caused the previous lock.
 */
export class Lockout {
  constructor(opts = {}) {
    this.opts = { ...LOCKOUT_DEFAULTS, ...(opts || {}) };
    this.entries = new Map();
  }

  configure(opts = {}) {
    if (Number.isFinite(Number(opts.maxFailures))) this.opts.maxFailures = Math.max(1, Number(opts.maxFailures));
    if (Number.isFinite(Number(opts.baseLockMs))) this.opts.baseLockMs = Math.max(1000, Number(opts.baseLockMs));
  }

  _entry(ip) {
    const key = String(ip || "unknown");
    let entry = this.entries.get(key);
    if (!entry) {
      entry = { failures: [], strikes: 0, lockedUntil: 0, lastFailAt: 0 };
      this.entries.set(key, entry);
    }
    return entry;
  }

  /** @returns {{locked:boolean,retryAfter:number,failures:number,strikes:number}} */
  state(ip, now = Date.now()) {
    const entry = this._entry(ip);
    if (entry.lockedUntil > now) {
      return {
        locked: true,
        retryAfter: Math.ceil((entry.lockedUntil - now) / 1000),
        failures: entry.failures.length,
        strikes: entry.strikes,
      };
    }
    // Slide the window so old failures stop counting.
    entry.failures = entry.failures.filter((at) => now - at < this.opts.windowMs);
    if (entry.lockedUntil !== 0 && entry.lockedUntil <= now) entry.lockedUntil = 0;
    return { locked: false, retryAfter: 0, failures: entry.failures.length, strikes: entry.strikes };
  }

  /** Record one failure; returns the (possibly now locked) state. */
  fail(ip, now = Date.now()) {
    const entry = this._entry(ip);
    if (entry.lockedUntil > now) return this.state(ip, now);
    if (entry.lastFailAt && now - entry.lastFailAt > this.opts.decayMs) entry.strikes = 0;
    entry.lastFailAt = now;
    entry.failures = entry.failures.filter((at) => now - at < this.opts.windowMs);
    entry.failures.push(now);
    if (entry.failures.length >= this.opts.maxFailures) {
      entry.strikes += 1;
      const lockMs = Math.min(this.opts.baseLockMs * 2 ** (entry.strikes - 1), this.opts.maxLockMs);
      entry.lockedUntil = now + lockMs;
      entry.failures = [];
    }
    return this.state(ip, now);
  }

  succeed(ip) {
    this.entries.delete(String(ip || "unknown"));
  }

  reset() {
    this.entries.clear();
  }

  /** Forget entries that can no longer matter (called from the state flush tick). */
  prune(now = Date.now()) {
    for (const [ip, entry] of this.entries) {
      const idle = now - Math.max(entry.lastFailAt || 0, entry.lockedUntil || 0);
      if (entry.lockedUntil <= now && entry.failures.length === 0 && idle > this.opts.windowMs) {
        this.entries.delete(ip);
      }
    }
  }
}
