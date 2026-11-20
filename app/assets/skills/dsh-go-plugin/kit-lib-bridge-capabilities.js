// Optional v1.2 capabilities (docs/design/native-plugins-protocol.md §11): manifest declarations,
// capability effects and the micro data model. Pure; vendored byte for byte into the plugin kit.
// A plugin that declares none of this parses, renders and validates exactly as under v1.1.
import { ID } from "./limits.js";
import { chars, isPlainObject, toJson } from "./util.js";

export const FEATURES = ["audio", "voice", "micro", "overlay", "files"];
/** Capability effect types (`micro` is a data channel, not an effect). */
export const EFFECT_FEATURES = ["audio", "voice", "overlay"];
export const PICKER_TYPES = ["pickFile", "pickImage"];
// Policy budgets, not measured platform limits. Keep one selection small enough for a
// phone and a remote host; account allocated upload buffers against the global budget.
export const FILE_LIMITS = Object.freeze({
  count: 4, bytes: 8 * 1024 * 1024, totalBytes: 16 * 1024 * 1024,
  cacheBytes: 64 * 1024 * 1024, requests: 8, requestMs: 5 * 60 * 1000,
  uploadMs: 30 * 1000, nameChars: 128,
});
export const RESOURCE_KINDS = ["media", "micro", "overlays"];
export const CAP_LIMITS = Object.freeze({
  mediaBytes: 16 * 1024 * 1024, mediaMs: 30000, mediaConcurrent: 2,
  leases: 8, pluginLeases: 2, eventBurst: 4, eventsPerSecond: 10,
  microBytes: 1024, microMs: 100, microSubs: 8, pluginMicroSubs: 2, textChars: 240, perKind: 2,
});
export const AUDIO_TYPES = new Set(["audio/mpeg", "audio/wav", "audio/ogg", "audio/mp4", "audio/aac"]);
export const CAP_EVENTS = Object.freeze({
  "audio.ended": "audio", "audio.stopped": "audio", "audio.error": "audio",
  "voice.speechStart": "voice", "voice.speechEnd": "voice", "voice.stopped": "voice", "voice.error": "voice",
  "overlay.closed": "overlay",
});
/** Events that end their role (each role ends at most once per lease). */
export const TERMINAL_EVENTS = new Set(["audio.ended", "audio.stopped", "audio.error", "voice.stopped", "voice.error", "overlay.closed"]);
export const featuresOf = (value) => (Array.isArray(value) ? FEATURES.filter((x) => value.includes(x)) : []);
export const KEY = /^[A-Za-z0-9_-]{1,128}$/;
const FEATURE_OF = { media: "audio", micro: "micro", overlays: "overlay" };

/** A micro value -> the complete small model `{text?, progress?}`, or undefined. */
export function microModel(value) {
  if (!isPlainObject(value)) return undefined;
  const keys = Object.keys(value);
  if (keys.length === 0 || keys.some((k) => k !== "text" && k !== "progress")) return undefined;
  if (value.text !== undefined && (typeof value.text !== "string" || chars(value.text) > CAP_LIMITS.textChars)) return undefined;
  if (value.progress !== undefined && value.progress !== null
    && (typeof value.progress !== "number" || !Number.isFinite(value.progress) || value.progress < 0 || value.progress > 1)) return undefined;
  const json = toJson(value);
  return json && json.bytes <= CAP_LIMITS.microBytes && Object.keys(json.value).length > 0 ? json.value : undefined;
}

/**
 * Reads `capabilities`, `contributes.{media,micro,overlays}`, action `requires` and panel `micro`
 * into `out` (a parseManifest result). Without `capabilities` the new keys stay what they were
 * under v1.1: an unknown surface or field, ignored.
 */
export function parseCapabilities(raw, out) {
  const ptr = (...parts) => `/dshGo/${parts.map((p) => String(p).replaceAll("~", "~0").replaceAll("/", "~1")).join("/")}`;
  const push = (path, code, severity, message) => out.issues.push({ path, code, severity, message });
  if (raw.capabilities === undefined) {
    for (const kind of RESOURCE_KINDS) {
      if (raw.contributes[kind] !== undefined) push(ptr("contributes", kind), "unknown-surface", "warn", `unknown surface ${kind}; declare dshGo.capabilities to use it`);
    }
    return;
  }
  if (!Array.isArray(raw.capabilities)) {
    push(ptr("capabilities"), "invalid-field", "error", "capabilities must be an array");
    out.capabilities = [];
  } else {
    out.capabilities = featuresOf(raw.capabilities);
    raw.capabilities.forEach((x, i) => {
      if (!FEATURES.includes(x)) push(ptr("capabilities", i), "invalid-field", "warn", `unknown capability ${String(x).slice(0, 40)}; ignored`);
    });
  }
  const caps = new Set(out.capabilities);
  for (const kind of RESOURCE_KINDS) {
    const list = raw.contributes[kind];
    if (list === undefined) continue;
    out.items[kind] = [];
    const feature = FEATURE_OF[kind];
    if (!Array.isArray(list)) { push(ptr("contributes", kind), "invalid-field", "error", `${kind} must be an array`); continue; }
    if (!caps.has(feature)) { push(ptr("contributes", kind), "invalid-field", "error", `${kind} needs the ${feature} capability`); continue; }
    list.forEach((it, i) => {
      const at = (...p) => ptr("contributes", kind, i, ...p);
      if (!isPlainObject(it) || typeof it.id !== "string" || !ID.test(it.id)) { push(at("id"), "invalid-field", "error", "id must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$"); return; }
      if (out.ids.has(it.id)) { push(at("id"), "duplicate-id", "error", `id ${it.id} is already used by ${out.ids.get(it.id)}`); return; }
      if (out.items[kind].length >= CAP_LIMITS.perKind) { push(at(), "too-many", "warn", `${kind} allows ${CAP_LIMITS.perKind} per plugin; the rest are ignored`); return; }
      const item = { id: it.id };
      if (kind === "overlays") {
        if (it.channel !== undefined) {
          if (!caps.has("micro") || !(out.items.micro ?? []).some((x) => x.id === it.channel)) { push(at("channel"), "invalid-field", "error", "channel must name one of this plugin's micro contributions (declared before it)"); return; }
          item.channel = it.channel;
        }
        if (it.text !== undefined) {
          if (typeof it.text !== "string" || chars(it.text) > CAP_LIMITS.textChars || Buffer.byteLength(it.text) > CAP_LIMITS.microBytes) { push(at("text"), "invalid-field", "error", "text is at most 240 characters"); return; }
          item.text = it.text;
        }
        if (item.channel === undefined && item.text === undefined) { push(at(), "missing-field", "error", "an overlay needs a channel or a text"); return; }
      }
      out.ids.set(it.id, kind);
      out.items[kind].push(item);
    });
  }
  for (const surface of ["composer.actions", "message.actions", "composer.tools", "session.actions"]) {
    const list = Array.isArray(raw.contributes[surface]) ? raw.contributes[surface] : [];
    for (const item of out.items[surface] ?? []) {
      if (item === null) continue;
      const i = out.rawIndex.get(item.id);
      const input = list[i];
      if (input?.requires === undefined) continue;
      // An unsatisfiable requirement fails closed: the action never becomes ready.
      const ok = Array.isArray(input.requires) && input.requires.length > 0 && input.requires.every((x) => caps.has(x));
      item.requires = ok ? featuresOf(input.requires) : ["unsupported"];
      if (!ok) push(ptr("contributes", surface, i, "requires"), "invalid-field", "error", "requires must list capabilities this plugin declares");
    }
  }
  const panels = Array.isArray(raw.contributes.panels) ? raw.contributes.panels : [];
  for (const item of out.items.panels) {
    if (item === null) continue;
    const i = out.rawIndex.get(item.id);
    const input = panels[i];
    if (input?.micro === undefined) continue;
    if (caps.has("micro") && (out.items.micro ?? []).some((x) => x.id === input.micro)) item.micro = input.micro;
    else push(ptr("contributes", "panels", i, "micro"), "invalid-field", "error", "micro must name one of this plugin's micro contributions");
  }
}

/**
 * Validates an audio / voice / overlay effect. `opts.capabilities` = {declared, features, media,
 * overlays}: what the plugin declared and what the tapping app negotiated. Not declared: the
 * v1.1 answer (unknown effect, no violation). Declared but not negotiated by this app: dropped,
 * no violation. Declared and negotiated but malformed: a bad effect.
 */
export function capabilityEffect(e, opts) {
  const unknown = (message) => ({ issue: { code: "unknown-effect", message, violation: false } });
  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });
  const p = opts.capabilities;
  if (!p || !(p.declared ?? []).includes(e.type)) return unknown(`unknown effect type ${JSON.stringify(e.type)}`);
  if (opts.static || opts.deferred || opts.fileResult) return bad(`${e.type} is only allowed in an immediate invoke result`);
  if (!(p.features ?? []).includes(e.type)) return unknown(`${e.type} is not supported by this app; dropped`);
  if (typeof e.instance !== "string" || !ID.test(e.instance)) return bad("instance must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$");
  // Unknown fields are dropped, as for every effect; the bridge adds `lease` itself.
  const out = { type: e.type, op: e.op, instance: e.instance };
  if (e.type === "audio") {
    if (!["play", "pause", "resume", "stop"].includes(e.op)) return bad("audio op must be play, pause, resume or stop");
    if (e.op === "play") {
      const id = typeof e.src === "string" && e.src.startsWith("media:") ? e.src.slice(6) : "";
      if (!(p.media ?? []).includes(id)) return bad("audio src must be media:<one of this plugin's media ids>");
      if (e.key !== undefined && (typeof e.key !== "string" || !KEY.test(e.key))) return bad("audio key must match ^[A-Za-z0-9_-]{1,128}$");
      out.src = e.src;
      if (e.key !== undefined) out.key = e.key;
    } else if (e.src !== undefined || e.key !== undefined) return bad(`audio ${e.op} takes no src or key`);
  } else if (e.type === "voice") {
    if (!["start", "stop"].includes(e.op)) return bad("voice op must be start or stop");
  } else {
    if (!["show", "hide"].includes(e.op)) return bad("overlay op must be show or hide");
    if (!(p.overlays ?? []).includes(e.id)) return bad("overlay id must be one of this plugin's overlays");
    out.id = e.id;
  }
  return { effect: out };
}

/** v1.3: selection is an immediate, explicitly tapped action, never a data emission. */
export function pickerEffect(e, opts) {
  const unknown = (message) => ({ issue: { code: "unknown-effect", message, violation: false } });
  const bad = (message) => ({ issue: { code: "bad-effect", message, violation: true } });
  if (!(opts.capabilities?.declared ?? []).includes("files")) return unknown(`unknown effect type ${JSON.stringify(e.type)}`);
  if (opts.static || opts.deferred || opts.fileResult) return bad(`${e.type} is only allowed in an immediate invoke result`);
  if (!(opts.capabilities?.features ?? []).includes("files")) return unknown("file selection is not supported by this app; dropped");
  if (opts.userGesture !== true) return bad("file selection needs an explicit user gesture");
  if (typeof e.action !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$/.test(e.action)) return bad("picker.action must be a 1-64 character callback action id");
  const maxFiles = e.maxFiles ?? 1;
  if (!Number.isInteger(maxFiles) || maxFiles < 1 || maxFiles > FILE_LIMITS.count) return bad(`picker.maxFiles must be 1..${FILE_LIMITS.count}`);
  return { effect: { type: e.type, action: e.action, maxFiles } };
}
