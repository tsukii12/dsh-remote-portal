// Small pure helpers shared by the native-plugin modules. Node built-ins only.
import { createHash } from "node:crypto";
import { LIMITS, SCOPE_KEYS, SEMVER, TONES } from "./limits.js";

export const isPlainObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v)
  && (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);

/** JSON round trip: a plain JSON copy plus its UTF-8 size, or undefined when not serializable. */
export function toJson(value) {
  try {
    const text = JSON.stringify(value);
    if (text === undefined) return undefined;
    return { value: JSON.parse(text), text, bytes: Buffer.byteLength(text) };
  } catch {
    return undefined;
  }
}

export const utf8Bytes = (s) => Buffer.byteLength(s, "utf8");
export const chars = (s) => [...s].length;
export const truncateChars = (s, n) => [...s].slice(0, n).join("");

/** Single-line display text: control characters and line breaks become spaces, runs collapse. */
export function cleanLine(s) {
  return s.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ").replace(/\s+/g, " ").trim();
}

/** A turn note push `{ turnId: { text, tone? } }` cleaned and cut to size, the newest turns kept. Undefined when malformed. */
export function sanitizeNotes(d) {
  if (d === null || d === undefined) return null;
  if (!isPlainObject(d)) return undefined;
  const out = {};
  for (const [turn, note] of Object.entries(d).slice(-LIMITS.turnNotesPerFeed)) {
    if (!isPlainObject(note) || typeof note.text !== "string" || turn.length > 64) continue;
    const text = cleanLine(note.text);
    if (text === "") continue;
    out[turn] = { text: chars(text) > LIMITS.textChars.turnNote ? truncateChars(text, LIMITS.textChars.turnNote) : text };
    if (TONES.includes(note.tone)) out[turn].tone = note.tone;
  }
  return out;
}

/** Multi-line payload text (insert / copy): keeps \n and \t, drops other control characters. */
export function cleanBlock(s) {
  return s.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "");
}

export const LOCALE = /^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$/;

/** Validates a Text value (string or locale map); returns the cleaned value or undefined. */
export function parseText(v) {
  if (typeof v === "string") {
    const s = cleanLine(v);
    return s === "" ? undefined : s;
  }
  if (!isPlainObject(v)) return undefined;
  const out = {};
  for (const [k, raw] of Object.entries(v)) {
    if (!LOCALE.test(k) || typeof raw !== "string") continue;
    const s = cleanLine(raw);
    if (s !== "") out[k.toLowerCase().replaceAll("_", "-")] = s;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

/** Text -> string for a locale: exact, language part, en, zh, first value. */
export function resolveText(text, locale) {
  if (text === undefined || text === null) return undefined;
  if (typeof text === "string") return text;
  const want = typeof locale === "string" ? locale.toLowerCase().replaceAll("_", "-") : "";
  if (want && text[want] !== undefined) return text[want];
  const lang = want.split("-")[0];
  if (lang && text[lang] !== undefined) return text[lang];
  if (lang) {
    const prefixed = Object.keys(text).find((k) => k.split("-")[0] === lang);
    if (prefixed !== undefined) return text[prefixed];
  }
  return text.en ?? text.zh ?? Object.values(text)[0];
}

export function compareSemver(a, b) {
  const pa = SEMVER.exec(a) ?? [0, 0, 0, 0];
  const pb = SEMVER.exec(b) ?? [0, 0, 0, 0];
  for (let i = 1; i <= 3; i++) {
    const d = Number(pa[i]) - Number(pb[i]);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

export function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false;
    return true;
  }
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  for (const k of ka) if (!Object.hasOwn(b, k) || !deepEqual(a[k], b[k])) return false;
  return true;
}

// JSON member names are data, including "__proto__"; never invoke inherited setters.
function setJsonMember(object, key, value) {
  Object.defineProperty(object, key, { value, enumerable: true, configurable: true, writable: true });
}

/**
 * RFC 7386 JSON Merge Patch turning `from` into `to` (both JSON values). Objects recurse, keys
 * missing from `to` become null, everything else is replaced whole. Returns undefined when equal.
 */
export function mergeDiff(from, to) {
  if (!isPlainObject(from) || !isPlainObject(to)) return deepEqual(from, to) ? undefined : to;
  const patch = {};
  let changed = false;
  for (const k of Object.keys(from)) {
    if (!Object.hasOwn(to, k) || to[k] === null) {
      if (from[k] !== null) { setJsonMember(patch, k, null); changed = true; }
    }
  }
  for (const [k, v] of Object.entries(to)) {
    if (v === null) continue;
    if (!Object.hasOwn(from, k) || from[k] === null) { setJsonMember(patch, k, v); changed = true; continue; }
    if (isPlainObject(from[k]) && isPlainObject(v)) {
      const sub = mergeDiff(from[k], v);
      if (sub !== undefined) { setJsonMember(patch, k, sub); changed = true; }
    } else if (!deepEqual(from[k], v)) {
      setJsonMember(patch, k, v);
      changed = true;
    }
  }
  return changed ? patch : undefined;
}

/** RFC 7386 apply; returns a new value. */
export function mergeApply(target, patch) {
  if (!isPlainObject(patch)) return patch;
  const out = isPlainObject(target) ? { ...target } : {};
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete out[k];
    else setJsonMember(out, k, mergeApply(Object.hasOwn(out, k) ? out[k] : undefined, v));
  }
  return out;
}

/** Drops null members recursively (what an app holding merged patches sees). */
export function withoutNulls(v) {
  if (Array.isArray(v)) return v.map(withoutNulls);
  if (!isPlainObject(v)) return v;
  const out = {};
  for (const [k, x] of Object.entries(v)) if (x !== null) setJsonMember(out, k, withoutNulls(x));
  return out;
}

const SCOPE_VALUE = /^[^\u0000-\u001f\u007f]{1,256}$/;

/** Canonical scope: known keys with valid string values, sorted. Invalid values -> undefined. */
export function normalizeScope(raw) {
  const scope = {};
  if (raw === undefined || raw === null) return { scope, key: "{}" };
  if (!isPlainObject(raw)) return undefined;
  for (const k of SCOPE_KEYS) {
    const v = raw[k];
    if (v === undefined || v === null || v === "") continue;
    if (typeof v !== "string" || !SCOPE_VALUE.test(v)) return undefined;
    scope[k] = v;
  }
  return { scope, key: JSON.stringify(scope) };
}

export const scopeMatches = (scope, partial) => Object.entries(partial).every(([k, v]) => scope[k] === v);

/** Typed nodes (objects with a string `type`) and their nesting depth in a view tree. */
export function viewStats(view) {
  let nodes = 0;
  let depth = 0;
  const walk = (v, d) => {
    if (Array.isArray(v)) { for (const x of v) walk(x, d); return; }
    if (v === null || typeof v !== "object") return;
    let next = d;
    if (typeof v.type === "string") {
      nodes++;
      next = d + 1;
      if (next > depth) depth = next;
    }
    for (const x of Object.values(v)) walk(x, next);
  };
  walk(view, 0);
  return { nodes, depth };
}

export const shortHash = (text) => createHash("sha256").update(text).digest("hex").slice(0, 12);

/** Resolves with the callback's value, or rejects with `{ timeout: true }` after `ms`. */
export function withTimeout(promise, ms) {
  let timer;
  return Promise.race([
    Promise.resolve(promise).finally(() => clearTimeout(timer)),
    new Promise((_, reject) => { timer = setTimeout(() => reject({ timeout: true }), ms); timer.unref?.(); }),
  ]);
}

/** Calls a plugin callback; synchronous throws become rejections. */
export function call(fn, ...args) {
  try {
    return Promise.resolve(fn(...args));
  } catch (error) {
    return Promise.reject(error);
  }
}

export const errorText = (error) => {
  if (error && error.timeout === true) return "timed out";
  const msg = error instanceof Error ? error.message : String(error);
  return msg.length > 200 ? `${msg.slice(0, 200)}…` : msg;
};
