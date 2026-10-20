/**
 * dsh-remote-portal — persistent state (single JSON file, mode 0600).
 *
 * Everything the gateway must survive a restart with lives here: the per-install
 * HMAC secret, the scrypt password record, portal sessions, the device registry,
 * outstanding pairing tokens, runtime config overrides, counters and the access
 * log. It lives in `<DSH_HOME>/dsh-remote-portal/state.json` (see
 * ARCHITECTURE.md §4.1), never in the plugin directory, because a plugin update
 * replaces the package but must not log the user out.
 *
 * Two rules drive the implementation:
 *
 *  1. **A corrupt file must never brick the portal.** The file is written by a
 *     process that can be killed mid-write (firmware update, OOM, `taskkill`),
 *     so `load()` falls back to `state.json.bak` and finally to a fresh state,
 *     and every field is normalised on the way in — a partial file is merged
 *     onto the defaults instead of throwing.
 *  2. **Writes are atomic.** `tmp + rename` on the same directory: `rename` is
 *     atomic on NTFS and POSIX, so a reader either sees the old or the new file,
 *     never a half-written one. The previous good copy is kept as `.bak`.
 *
 * Windows note: `mode: 0o600` is a no-op on NTFS (Node maps it to the read-only
 * attribute only). The file lives under the user profile, which already inherits
 * a user-only ACL, so this is defence in depth rather than the real boundary.
 */
import {
  chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync,
  unlinkSync, writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";

export const STATE_FILE = "state.json";
export const STATE_VERSION = 1;
/** The panel shows the last requests; 100 is plenty and keeps the file small. */
export const ACCESS_LOG_LIMIT = 100;
/** A device with no session for this long is dropped from the registry. */
const DEVICE_IDLE_MS = 180 * 24 * 60 * 60 * 1000;

/** `<DSH_HOME>/dsh-remote-portal`, where DSH_HOME defaults to `~/.dsh`. */
export function defaultStateDir(env = process.env, home = homedir()) {
  const raw = String(env?.DSH_HOME ?? "").trim();
  const base = raw !== "" ? raw : join(home, ".dsh");
  return join(base, "dsh-remote-portal");
}

/** A complete, valid state document. Every field the code touches is present. */
export function emptyState(now = Date.now()) {
  return {
    version: STATE_VERSION,
    createdAt: now,
    updatedAt: now,
    // Per-install HMAC key for portal session cookies. Regenerating it is the
    // same operation as "log every device out", so it is created once and only
    // removed by an explicit wipe (a corrupt file loses it, see load()).
    secret: randomBytes(32).toString("base64url"),
    password: null,
    sessions: {},
    devices: {},
    pairing: {},
    overrides: {},
    counters: { requests: 0, bytesOut: 0, logins: 0, failures: 0, lastRequestAt: 0, lastLoginAt: 0 },
    accessLog: [],
  };
}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
const str = (v, d = "") => (typeof v === "string" ? v : d);

/**
 * Merge an arbitrary parsed object onto the defaults.
 *
 * Why not validate strictly and reject: this file is ours, it is not an input
 * surface, and a version bump that adds a field must not wipe a user's password
 * because one field was unknown. Unknown keys are dropped, known keys are
 * coerced, and anything unusable falls back to the default.
 */
function normalizeState(raw, now) {
  const base = emptyState(now);
  if (!isObject(raw)) return base;
  const out = base;

  if (typeof raw.secret === "string" && raw.secret.length >= 16) out.secret = raw.secret;
  out.createdAt = num(raw.createdAt, now);
  out.updatedAt = num(raw.updatedAt, now);

  if (isObject(raw.password) && typeof raw.password.hash === "string" && typeof raw.password.salt === "string") {
    out.password = {
      alg: str(raw.password.alg, "scrypt"),
      salt: raw.password.salt,
      hash: raw.password.hash,
      N: num(raw.password.N, 16384),
      r: num(raw.password.r, 8),
      p: num(raw.password.p, 1),
      keylen: num(raw.password.keylen, 64),
      updatedAt: num(raw.password.updatedAt, now),
    };
  }

  if (isObject(raw.sessions)) {
    for (const [id, s] of Object.entries(raw.sessions)) {
      if (!isObject(s) || typeof s.id !== "string") continue;
      out.sessions[id] = {
        id: s.id,
        issuedAt: num(s.issuedAt),
        expiresAt: num(s.expiresAt),
        uaHash: str(s.uaHash),
        deviceId: str(s.deviceId),
        ip: str(s.ip),
        via: str(s.via, "password"),
        createdAt: num(s.createdAt, num(s.issuedAt)),
        lastSeenAt: num(s.lastSeenAt, num(s.issuedAt)),
      };
    }
  }

  if (isObject(raw.devices)) {
    for (const [id, d] of Object.entries(raw.devices)) {
      if (!isObject(d) || typeof d.id !== "string") continue;
      out.devices[id] = {
        id: d.id,
        label: str(d.label, "device"),
        createdAt: num(d.createdAt),
        lastSeenAt: num(d.lastSeenAt, num(d.createdAt)),
        ip: str(d.ip),
        ua: str(d.ua),
      };
    }
  }

  if (isObject(raw.pairing)) {
    for (const [id, p] of Object.entries(raw.pairing)) {
      if (!isObject(p) || typeof p.hash !== "string") continue;
      out.pairing[id] = {
        id: str(p.id, id),
        hash: p.hash,
        label: str(p.label),
        createdAt: num(p.createdAt),
        expiresAt: num(p.expiresAt),
        usedAt: num(p.usedAt),
      };
    }
  }

  if (isObject(raw.overrides)) out.overrides = sanitizeOverrides(raw.overrides);

  if (isObject(raw.counters)) {
    const c = raw.counters;
    out.counters = {
      requests: Math.max(0, num(c.requests)),
      bytesOut: Math.max(0, num(c.bytesOut)),
      logins: Math.max(0, num(c.logins)),
      failures: Math.max(0, num(c.failures)),
      lastRequestAt: num(c.lastRequestAt),
      lastLoginAt: num(c.lastLoginAt),
    };
  }

  if (Array.isArray(raw.accessLog)) {
    out.accessLog = raw.accessLog
      .filter((e) => isObject(e) && typeof e.path === "string")
      .slice(-ACCESS_LOG_LIMIT)
      .map((e) => ({
        at: num(e.at),
        ip: str(e.ip),
        method: str(e.method, "GET"),
        path: str(e.path).slice(0, 300),
        status: num(e.status),
        ms: num(e.ms),
        auth: str(e.auth, "anon"),
        ua: str(e.ua).slice(0, 120),
      }));
  }

  return out;
}

/**
 * Runtime config overrides are persisted so a toggle made in the panel survives
 * a restart (§5). Only the known keys are kept — a hand-edited file must not be
 * able to inject arbitrary values into the effective config.
 */
export function sanitizeOverrides(raw) {
  const out = {};
  if (!isObject(raw)) return out;
  if (typeof raw.enabled === "boolean") out.enabled = raw.enabled;
  if (typeof raw.host === "string" && raw.host.trim() !== "") out.host = raw.host.trim();
  if (Number.isInteger(Number(raw.port)) && Number(raw.port) >= 0 && Number(raw.port) <= 65535) out.port = Number(raw.port);
  if (typeof raw.mobile === "boolean") out.mobile = raw.mobile;
  if (isObject(raw.auth)) {
    const auth = {};
    if (["password", "pair-only", "open"].includes(raw.auth.mode)) auth.mode = raw.auth.mode;
    if (Number.isFinite(Number(raw.auth.sessionDays))) auth.sessionDays = Number(raw.auth.sessionDays);
    if (Number.isFinite(Number(raw.auth.maxFailures))) auth.maxFailures = Number(raw.auth.maxFailures);
    if (Number.isFinite(Number(raw.auth.lockSeconds))) auth.lockSeconds = Number(raw.auth.lockSeconds);
    if (Object.keys(auth).length > 0) out.auth = auth;
  }
  if (raw.tls === null) out.tls = null;
  else if (isObject(raw.tls) && typeof raw.tls.certFile === "string" && typeof raw.tls.keyFile === "string") {
    out.tls = { certFile: raw.tls.certFile, keyFile: raw.tls.keyFile };
  }
  // The public relay is configured from the panel, so its override has to
  // survive a restart like every other key. Dropping it here (as an earlier
  // build did) silently turned public access off on the next boot.
  if (raw.tunnel === null) out.tunnel = null;
  else if (isObject(raw.tunnel)) {
    const url = typeof raw.tunnel.url === "string" ? raw.tunnel.url.trim() : "";
    const token = typeof raw.tunnel.token === "string" ? raw.tunnel.token.trim() : "";
    let protocol = "";
    try { protocol = new URL(url).protocol; } catch { protocol = ""; }
    if (url !== "" && token !== "" && ["tls:", "tcp:", "wss:", "https:"].includes(protocol)) {
      out.tunnel = {
        url,
        token,
        caFile: typeof raw.tunnel.caFile === "string" ? raw.tunnel.caFile.trim() : "",
        insecure: raw.tunnel.insecure === true,
      };
    }
  }
  return out;
}

export class StateStore {
  /**
   * @param {{ dir?: string, log?: {info:Function,warn:Function,error:Function} }} [opts]
   */
  constructor({ dir, log } = {}) {
    this.dir = dir && String(dir).trim() !== "" ? String(dir) : defaultStateDir();
    this.path = join(this.dir, STATE_FILE);
    this.bakPath = `${this.path}.bak`;
    this.log = log || { info() {}, warn() {}, error() {} };
    this.data = null;
    this.recovered = false;
    this._writeFailed = false;
  }

  /** Read (or create) the state document. Never throws. */
  load(now = Date.now()) {
    if (this.data) return this.data;
    const primary = this._read(this.path);
    if (primary.ok) {
      this.data = normalizeState(primary.value, now);
      this.prune(now);
      return this.data;
    }
    // A corrupt primary is kept next to the file (`state.json.corrupt-<ts>`)
    // instead of deleted: it is the only copy of the password hash, and a user
    // who mistyped a password deserves a chance to recover the old one.
    if (primary.exists) {
      const keep = `${this.path}.corrupt-${now}`;
      try { renameSync(this.path, keep); } catch { /* best effort */ }
      this.log.warn(`state.json was unreadable (${primary.reason}); kept a copy at ${keep}`);
    }
    const backup = this._read(this.bakPath);
    if (backup.ok) {
      this.data = normalizeState(backup.value, now);
      this.recovered = true;
      this.prune(now);
      this.log.warn("state.json recovered from state.json.bak");
      this.save(); // promote the backup back to the primary file
      return this.data;
    }
    this.data = emptyState(now);
    this.recovered = !primary.exists;
    // Persist immediately so the HMAC secret is stable even if the process dies
    // before the first login (otherwise every restart would silently log out
    // every device, and a minted cookie would be unverifiable after a crash).
    this.save();
    return this.data;
  }

  _read(file) {
    try {
      const text = readFileSync(file, "utf8");
      if (!text.trim()) return { ok: false, exists: true, reason: "empty" };
      return { ok: true, value: JSON.parse(text) };
    } catch (error) {
      if (error && error.code === "ENOENT") return { ok: false, exists: false, reason: "missing" };
      return { ok: false, exists: true, reason: String(error?.message || error) };
    }
  }

  /**
   * Atomic write: tmp file in the same directory, fsync-free rename.
   * Synchronous on purpose — state changes are small, rare, and must be visible
   * to the very next request (login → cookie → immediate proxy call).
   */
  save(data = this.data) {
    if (!data) return false;
    data.updatedAt = Date.now();
    try {
      mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    } catch (error) {
      this._warnOnce(`state directory is not writable: ${error?.message || error}`);
      return false;
    }
    const tmp = `${this.path}.tmp-${process.pid}-${randomBytes(4).toString("hex")}`;
    try {
      writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
      // Keep the previous good copy. Cheap (a few KB) and it is the only thing
      // that makes the corrupt-primary path above worth anything.
      try { if (existsSync(this.path)) copyFileSync(this.path, this.bakPath); } catch { /* best effort */ }
      renameSync(tmp, this.path); // atomic replace on NTFS and POSIX
      try { chmodSync(this.path, 0o600); } catch { /* no-op on Windows */ }
      if (this._writeFailed) this.log.info("state.json is writable again");
      this._writeFailed = false;
      return true;
    } catch (error) {
      try { unlinkSync(tmp); } catch { /* already gone */ }
      this._writeFailed = true;
      this._warnOnce(`state.json write failed: ${error?.message || error}`);
      return false;
    }
  }

  _warnOnce(message) {
    if (this._writeFailed) return;
    this._writeFailed = true;
    this.log.warn(message);
  }

  /**
   * Drop expired sessions / pairing tokens, cap the access log, forget idle
   * devices. Mutates memory only; callers decide when to persist (status() must
   * be cheap and side-effect free).
   */
  prune(now = Date.now(), data = this.data) {
    if (!data) return false;
    let changed = false;
    for (const [id, s] of Object.entries(data.sessions)) {
      if (!s || !(s.expiresAt > now)) { delete data.sessions[id]; changed = true; }
    }
    for (const [id, p] of Object.entries(data.pairing)) {
      // Expired tokens are dropped; *used* tokens are kept until they expire so
      // a replay is answered with "already used" instead of "unknown".
      if (!p || !(p.expiresAt > now)) { delete data.pairing[id]; changed = true; }
    }
    const liveDevices = new Set(Object.values(data.sessions).map((s) => s.deviceId).filter(Boolean));
    for (const [id, d] of Object.entries(data.devices)) {
      const seen = Math.max(Number(d.lastSeenAt) || 0, Number(d.createdAt) || 0);
      if (!liveDevices.has(id) && now - seen > DEVICE_IDLE_MS) { delete data.devices[id]; changed = true; }
    }
    if (data.accessLog.length > ACCESS_LOG_LIMIT) {
      data.accessLog.splice(0, data.accessLog.length - ACCESS_LOG_LIMIT);
      changed = true;
    }
    return changed;
  }

  appendAccess(entry, now = Date.now()) {
    const data = this.load(now);
    data.accessLog.push(entry);
    if (data.accessLog.length > ACCESS_LOG_LIMIT) data.accessLog.splice(0, data.accessLog.length - ACCESS_LOG_LIMIT);
  }
}

