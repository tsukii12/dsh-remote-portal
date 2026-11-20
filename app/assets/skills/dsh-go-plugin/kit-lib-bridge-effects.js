// Effect whitelist (docs/design/native-plugins-protocol.md §5): shorthand expansion, validation
// and normalization of what a handler returns, and of manifest static effects.
import { capabilityEffect, EFFECT_FEATURES, pickerEffect, PICKER_TYPES } from "./capabilities.js";
import { LIMITS } from "./limits.js";
import { chars, cleanBlock, cleanLine, isPlainObject, toJson, truncateChars } from "./util.js";

export const STATIC_TYPES = new Set(["insert", "command", "open", "link", "toast", "copy"]);
export const ALL_TYPES = new Set([...STATIC_TYPES, "refresh", "patch"]);
/** What a deferred result may carry (protocol §4.7): no command / open / link / refresh. */
export const DEFERRED_TYPES = new Set(["insert", "copy", "toast", "patch"]);
const SHORTHAND = ["insert", "command", "open", "link", "toast", "copy", "refresh", "patch"];
const COMMAND = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const PAGE = /^(panel:([A-Za-z0-9][A-Za-z0-9_.-]{0,39})|[a-z][a-z0-9-]{0,31})$/;
const ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/;

/** Handler return value -> list of raw effect candidates. Returns undefined for a malformed shape. */
export function expand(result) {
  if (result === undefined || result === null) return [];
  const list = Array.isArray(result) ? result : [result];
  const out = [];
  for (const item of list) {
    if (!isPlainObject(item)) return undefined;
    if (typeof item.type === "string") { out.push(item); continue; }
    const keys = Object.keys(item).filter((k) => SHORTHAND.includes(k));
    if (keys.length === 0) return undefined;
    for (const k of keys) out.push(fromShorthand(k, item[k]));
  }
  return out;
}

function fromShorthand(key, v) {
  switch (key) {
    case "insert": case "toast": case "copy": return { type: key, text: v };
    case "link": return { type: "link", url: v };
    case "open": return { type: "open", page: v };
    case "command": return isPlainObject(v) ? { type: "command", name: v.name, args: v.args } : { type: "command", name: v };
    case "refresh": return v === true ? { type: "refresh" } : { type: "refresh", id: v };
    case "patch": return { type: "patch", data: v };
  }
  return { type: key };
}

/**
 * Validates one effect. `opts`: { panels: Set<panel id>, source?: panel id the tap came from,
 * static?: true for manifest effects }. Returns { effect } | { issue: {code, message, violation} }.
 */
export function validate(e, opts) {
  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });
  if (!isPlainObject(e) || typeof e.type !== "string") return bad("effect must be an object with a string type");
  if (EFFECT_FEATURES.includes(e.type)) return capabilityEffect(e, opts);   // v1.2, optional
  if (PICKER_TYPES.includes(e.type)) return pickerEffect(e, opts);         // v1.3, optional
  if (opts.fileResult && !["patch", "refresh", "toast"].includes(e.type)) return bad(`${e.type} is not allowed in a file selection callback`);
  const allowed = opts.static ? STATIC_TYPES : opts.deferred ? DEFERRED_TYPES : ALL_TYPES;
  if (!ALL_TYPES.has(e.type)) return { issue: { code: "unknown-effect", message: `unknown effect type ${JSON.stringify(e.type).slice(0, 40)}`, violation: false } };
  if (!allowed.has(e.type)) return bad(opts.deferred ? `${e.type} is not allowed in a deferred result (only insert, copy, toast, patch)` : `${e.type} is not allowed here`);
  const ownPanel = (id) => typeof id === "string" && ID.test(id) && opts.panels.has(id);
  switch (e.type) {
    case "insert": case "copy": {
      if (typeof e.text !== "string") return bad(`${e.type}.text must be a string`);
      const text = cleanBlock(e.text);
      const max = e.type === "insert" ? LIMITS.insertChars : LIMITS.copyChars;
      if (text === "" || chars(text) > max) return bad(`${e.type}.text must be 1-${max} characters`);
      return { effect: { type: e.type, text } };
    }
    case "toast": {
      if (typeof e.text !== "string") return bad("toast.text must be a string");
      const text = cleanLine(e.text);
      if (text === "") return bad("toast.text is empty");
      if (chars(text) > LIMITS.textChars.toast) {
        return { effect: { type: "toast", text: truncateChars(text, LIMITS.textChars.toast) },
          issue: { code: "too-long", message: `toast exceeds ${LIMITS.textChars.toast} characters; truncated`, violation: false } };
      }
      return { effect: { type: "toast", text } };
    }
    case "command": {
      // Permission selection belongs to the user, never to a native effect.
      if (e.name === "permission") return bad("native effects cannot select permission presets");
      if (typeof e.name !== "string" || !COMMAND.test(e.name)) return bad("command.name is not a command name (no leading /)");
      if (e.args !== undefined && (typeof e.args !== "string" || chars(e.args) > LIMITS.commandArgsChars)) return bad(`command.args must be a string of <= ${LIMITS.commandArgsChars} characters`);
      return { effect: e.args === undefined || e.args === "" ? { type: "command", name: e.name } : { type: "command", name: e.name, args: cleanBlock(e.args) } };
    }
    case "open": {
      const m = typeof e.page === "string" ? PAGE.exec(e.page) : null;
      if (!m) return bad("open.page must be an app page id or panel:<id>");
      if (m[2] !== undefined && !opts.panels.has(m[2])) return bad(`open.page names a panel this plugin does not declare: ${m[2]}`);
      return { effect: { type: "open", page: e.page } };
    }
    case "link": {
      if (typeof e.url !== "string" || e.url.length > LIMITS.linkChars) return bad(`link.url must be a string of <= ${LIMITS.linkChars} characters`);
      let url;
      try { url = new URL(e.url); } catch { return bad("link.url is not a URL"); }
      if (url.protocol !== "https:") return bad("link.url must be https");
      if (url.username !== "" || url.password !== "") return bad("link.url must not carry credentials");
      return { effect: { type: "link", url: url.href } };
    }
    case "refresh": {
      const id = e.id ?? opts.source;
      if (!ownPanel(id)) return bad("refresh needs one of this plugin's panels (id, or a tap from a panel)");
      return { effect: { type: "refresh", id } };
    }
    case "patch": {
      const id = e.id ?? opts.source;
      if (!ownPanel(id)) return bad("patch needs one of this plugin's panels (id, or a tap from a panel)");
      if (!isPlainObject(e.data)) return bad("patch.data must be an object (JSON Merge Patch)");
      const json = toJson(e.data);
      if (json === undefined || json.bytes > LIMITS.patchBytes) return bad(`patch.data must be JSON of <= ${LIMITS.patchBytes} bytes`);
      return { effect: { type: "patch", id, data: json.value } };
    }
  }
  return bad("unreachable");
}

/**
 * A handler result -> { effects, issues, violation }. Malformed results, structurally bad
 * effects and too many effects count as a violation; unknown types and toast truncation do not.
 */
export function normalize(result, opts) {
  const issues = [];
  const list = expand(result);
  if (list === undefined) {
    return { effects: [], issues: [{ path: "/runtime/effects", code: "bad-effect", severity: "warn", message: "handler returned neither an effect, an effect list nor a shorthand object" }], violation: true };
  }
  let violation = false;
  const effects = [];
  for (const [i, raw] of list.entries()) {
    if (effects.length >= LIMITS.effectsPerInvoke) {
      issues.push({ path: `/runtime/effects/${i}`, code: "too-many", severity: "warn", message: `more than ${LIMITS.effectsPerInvoke} effects; the rest were dropped` });
      violation = true;
      break;
    }
    const r = validate(raw, opts);
    if (r.issue) {
      issues.push({ path: `/runtime/effects/${i}`, code: r.issue.code, severity: "warn", message: r.issue.message });
      if (r.issue.violation) violation = true;
    }
    if (r.effect) effects.push(r.effect);
  }
  return { effects, issues, violation };
}

/** SDK alias: handler return value -> { effects, issues, violation } (opts as for normalize). */
export const checkEffects = normalize;

/**
 * Deferred handler result (protocol §4.7): `{ pending: { label?, timeoutMs? } | true, result }`
 * where `result` is a Promise or `(signal) => value | Promise`. Returns undefined when `result`
 * is not a deferred request; otherwise { ok, label?, timeoutMs, work, issues, violation }.
 */
export function splitPending(result) {
  if (!isPlainObject(result) || result.pending === undefined) return undefined;
  const issues = [];
  const p = result.pending;
  const work = result.result;
  const bad = (message) => ({ ok: false, issues: [{ path: "/runtime/pending", code: "bad-effect", severity: "warn", message }], violation: true });
  if (p !== true && !isPlainObject(p)) return bad("pending must be true or { label?, timeoutMs? }");
  if (typeof work !== "function" && !(work !== null && typeof work === "object" && typeof work.then === "function")) {
    return bad("pending needs result: a Promise or (signal) => Promise");
  }
  const extra = Object.keys(result).filter((k) => k !== "pending" && k !== "result");
  if (extra.length > 0) issues.push({ path: "/runtime/pending", code: "bad-effect", severity: "warn", message: `ignored next to pending: ${extra.join(", ").slice(0, 80)}` });
  let label;
  if (isPlainObject(p) && typeof p.label === "string") {
    label = cleanLine(p.label);
    if (label === "") label = undefined;
    else if (chars(label) > LIMITS.pendingLabelChars) {
      label = truncateChars(label, LIMITS.pendingLabelChars);
      issues.push({ path: "/runtime/pending/label", code: "too-long", severity: "warn", message: `pending label exceeds ${LIMITS.pendingLabelChars} characters; truncated` });
    }
  }
  const raw = isPlainObject(p) ? p.timeoutMs : undefined;
  const timeoutMs = typeof raw === "number" && Number.isFinite(raw)
    ? Math.min(LIMITS.pendingMaxMs, Math.max(LIMITS.pendingMinMs, Math.round(raw)))
    : LIMITS.pendingDefaultMs;
  return { ok: true, label, timeoutMs, work, issues, violation: false };
}
